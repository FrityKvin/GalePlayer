import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GaleCore

/// 右侧面板：播放列表 / 关键帧两个标签页。
/// 播放列表侧栏（播放列表 + 关键帧两个标签）。
struct SidebarPanel: View {
    @Binding var tab: SidebarTab
    @Binding var visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SidebarTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .playlist:
                PlaylistPanel()
            case .chapters:
                ChapterPanel()
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity)
        .background(.background)
    }
}

// MARK: - 播放列表

struct PlaylistPanel: View {
    @EnvironmentObject private var core: PlayerCore
    @EnvironmentObject private var settings: AppSettings
    @State private var selection: PlaylistNode.ID?
    /// 自动展开的文件夹：进入其中某个媒体播放时展开，离开时收起。
    /// 没有这个，拖入文件夹后子项始终折叠着 —— 高亮画在看不见的行上，
    /// 用户看到的就是「不高亮」。
    @State private var expandedFolders: Set<PlaylistNode.ID> = []

    var body: some View {
        RenderCounters.playlistPanel += 1   // 资源自检用
        return VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            dropFiles(providers)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("播放列表")
                .font(.headline)
            Text("\(settings.mediaCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // 图文 / 文字两种模式 —— 原版 playListImageMode / playListTextMode
            Picker("", selection: $settings.imageMode) {
                Image(systemName: "text.alignleft").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 72)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if settings.playlistItems.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 30, weight: .thin))
                    .foregroundStyle(.tertiary)
                Text("列表是空的")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("拖文件/文件夹进来，或用下方按钮添加")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(selection: $selection) {
                // 规范化**一次**，逐行只做字符串比较（不要进 ForEach 调用规范化）
                let playingPath = PlaylistPanel.canonicalPath(of: core.currentURL)
                // 渲染**扁平化后的可见行**，而不是把文件夹的子项塞进一个 DisclosureGroup：
                // List 只对顶层行做虚拟化，嵌在 DisclosureGroup 里的 2000 个子项会
                // 全部实例化（实测 200 项主线程延迟 10.7ms → 2000 项 33.3ms、峰值 348ms）。
                // 扁平化后折叠状态只影响数组内容，可见行数与 List 的懒加载对齐。
                ForEach(visibleRows, id: \.node.id) { row in
                    PlaylistRow(
                        node: row.node,
                        depth: row.depth,
                        imageMode: settings.imageMode,
                        selection: $selection,
                        onToggleFavorite: { settings.toggleFavorite([$0]) },
                        isCurrent: PlaylistRow.isCurrent(row.node, playingPath: playingPath),
                        expandedFolders: $expandedFolders,
                        playingPath: playingPath
                    )
                    .moveDisabled(row.depth > 0)   // 只允许拖拽调整顶层顺序（与原行为一致）
                }
                .onMove { indices, newOffset in
                    settings.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: core.currentURL) { _, _ in
                syncExpansionWithPlayback()
            }
            .onAppear { syncExpansionWithPlayback() }
            .contextMenu(forSelectionType: PlaylistNode.ID.self) { ids in
                let starred = ids.first
                    .flatMap { find($0, in: settings.playlistItems)?.isFavorite } ?? false
                Button(starred ? "取消星标" : "加星标") { settings.setFavorite(ids, to: !starred) }
                Divider()
                Button("移除") { settings.remove(ids: ids) }
                Button("在访达中显示") {
                    if let first = ids.first, let node = find(first, in: settings.playlistItems) {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                }
            } primaryAction: { ids in
                // 文件夹行现在也可选中（有了 tag），双击它不该触发播放
                if let first = ids.first,
                   let node = find(first, in: settings.playlistItems),
                   !node.resolvedIsFolder {
                    core.play(node: node, in: settings.orderedMedia)
                }
            }
        }
    }

    /// 正在播放的媒体属于哪个文件夹 → 自动展开它。
    ///
    /// 没有这条，拖入文件夹后 toggle 默认折叠，**高亮画在看不见的子项上**，
    /// 表现就是「播放列表不高亮正在播放的文件」。
    private func syncExpansionWithPlayback() {
        guard let current = core.currentURL else { return }
        // 规范化一次即可：节点 URL 在创建/载入时已规范化，子项只需字符串比较。
        // 旧写法对**每个子项**调 `path(of:)`（符号链接解析=系统调用），
        // 2000 个子项每次换片就是 2000 次系统调用 —— 这是换集时的卡顿来源之一。
        let target = Playlist.canonical(current).path

        func owner(_ nodes: [PlaylistNode]) -> PlaylistNode.ID? {
            for node in nodes {
                if node.resolvedIsFolder {
                    if node.flattenedMedia.contains(where: { $0.url.path == target }) {
                        return node.id
                    }
                }
            }
            return nil
        }
        guard let folderID = owner(settings.playlistItems) else { return }
        if expandedFolders.contains(folderID) { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            _ = expandedFolders.insert(folderID)
        }
    }

    private func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openFiles()
            } label: {
                Label("文件", systemImage: "doc.badge.plus")
            }
            Button {
                openFolder()
            } label: {
                Label("文件夹", systemImage: "folder.badge.plus")
            }
            Spacer()
            Button {
                core.exportPlaylist()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(settings.playlistItems.isEmpty)
            .help("导出播放列表（含文件夹层级、星标与关键帧）")
            Button {
                core.importPlaylist()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("导入 Gale 播放列表（追加，不清空当前列表）")
            Button(role: .destructive) {
                settings.clearPlaylist()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(settings.playlistItems.isEmpty)
            .help("清空播放列表")
        }
        .controlSize(.small)
        .padding(8)
    }

    // MARK: - 动作

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaTypes.all.sorted().compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        settings.addFiles(urls.filter { !isDirectory($0) })
        for dir in urls where isDirectory(dir) { settings.addFolder(dir) }
        if core.currentURL == nil, let first = settings.orderedMedia.first {
            core.play(node: first, in: settings.orderedMedia)
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.addFolder(url)
    }

    private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if isDirectory(url) { settings.addFolder(url) } else { settings.addFiles([url]) }
                }
            }
        }
        return true
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// 是否是正在播放的那一项（路径按 symlink 归一化后再比，避免 /tmp 与 /private/tmp 不一致）。
    /// 当前播放路径的规范化形式（一次系统调用）；nil 表示没有在播。
    static func canonicalPath(of url: URL?) -> String? {
        url.map { Playlist.canonical($0).path }
    }

    /// 一行可见项：节点 + 缩进层级。
    struct VisibleRow: Identifiable {
        let node: PlaylistNode
        let depth: Int
        var id: PlaylistNode.ID { node.id }
    }

    /// 按「顶层项 + 已展开文件夹的子项」拉平成 List 可直接虚拟化的行数组。
    ///
    /// 子项本身已经是扁平的（拖入文件夹 = 一个 toggle + 递归扫出的媒体列表），
    /// 所以只需一层展开，不需要递归。
    private var visibleRows: [VisibleRow] {
        var rows: [VisibleRow] = []
        rows.reserveCapacity(settings.playlistItems.count * 2)
        for node in settings.playlistItems {
            rows.append(VisibleRow(node: node, depth: 0))
            guard node.resolvedIsFolder,
                  expandedFolders.contains(node.id),
                  let children = node.children
            else { continue }
            for child in children {
                rows.append(VisibleRow(node: child, depth: 1))
            }
        }
        return rows
    }

    private func find(_ id: UUID, in nodes: [PlaylistNode]) -> PlaylistNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let hit = find(id, in: children) { return hit }
        }
        return nil
    }
}

struct PlaylistRow: View {   // internal：--perf-test 要量它的高亮判定成本
    /// 「这一行是不是正在播放」的**唯一**判定。
    ///
    /// 放在类型上而不是只放在 PlaylistPanel，是为了文件夹子项也能各自判断 ——
    /// 递归时若把父级（文件夹，恒为 false）的结果透传下去，所有子项就永远不高亮。
    /// 传入的必须是**已规范化**的路径（`Playlist.canonical` 之后的 `.path`）：
    /// 节点 URL 在创建/载入时已规范化，所以这里退化成纯字符串比较、零系统调用。
    /// 早先的写法对「正在播放的 URL」和「每个行 URL」各调一次
    /// `resolvingSymlinksInPath()`——1000 行就是 2000 次文件系统调用，
    /// 实测 24ms/次重绘，长列表滚动卡顿的主因。
    static func isCurrent(_ node: PlaylistNode, playingPath: String?) -> Bool {
        guard let playingPath, !node.resolvedIsFolder else { return false }
        return node.url.path == playingPath
    }

    let node: PlaylistNode
    /// 缩进层级（0 = 顶层项，1 = 文件夹子项）
    let depth: Int
    let imageMode: Bool
    @Binding var selection: PlaylistNode.ID?
    /// 切换星标；文件夹节点传 nil 表示不提供（避免整目录误标）。
    var onToggleFavorite: ((PlaylistNode.ID) -> Void)?
    /// 是否正在播放（高亮用）
    var isCurrent: Bool = false
    /// 所属面板的「自动展开」集合（文件夹行用它决定自己是否展开）
    @Binding var expandedFolders: Set<PlaylistNode.ID>
    /// 当前正在播放的规范化路径（逐行判定高亮用）
    let playingPath: String?

    private var isExpanded: Bool { expandedFolders.contains(node.id) }

    /// 展开/收起自己（子项由 PlaylistPanel 的 visibleRows 负责生成）。
    private func toggleExpansion() {
        if isExpanded { expandedFolders.remove(node.id) }
        else { expandedFolders.insert(node.id) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            // 文件夹：自绘展开箭头。不再用 DisclosureGroup ——
            // 它会把子项全部塞进同一个 List cell，List 的虚拟化失效。
            if node.resolvedIsFolder {
                Button(action: toggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起" : "展开")
            } else if depth > 0 {
                Spacer().frame(width: 14)
            }
            rowLabel
        }
        // 高亮底色必须加在**行级**视图上：加在内层 HStack 上不生效
        .listRowBackground(
            isCurrent && !node.resolvedIsFolder
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
        .tag(node.id)
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            if imageMode {
                ThumbnailView(url: node.url)
                    .frame(width: 64, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: node.isFolder ? "folder" : "film")
                    .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
                    .frame(width: 16)
            }
            // 正在播放：前置 ▶ 标记（比只改颜色更醒目，色弱用户也能识别）
            if isCurrent && !node.resolvedIsFolder {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 10)
            }

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isCurrent && !node.resolvedIsFolder ? .semibold : .regular)
                .foregroundStyle(isCurrent && !node.resolvedIsFolder ? Color.accentColor : .primary)

            Spacer(minLength: 4)

            // 星标：点击直接切换，不影响选中与播放
            if let onToggleFavorite {
                Button {
                    onToggleFavorite(node.id)
                } label: {
                    Image(systemName: node.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(node.isFavorite ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(node.isFavorite ? "取消星标" : "加星标")
            }
        }
        .padding(.vertical, imageMode ? 3 : 0)
    }
}

/// 缩略图（异步生成 + 内存缓存），对应原版图文播放列表模式。
struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

// MARK: - 关键帧面板

struct ChapterPanel: View {
    @EnvironmentObject private var core: PlayerCore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if core.chapterTimes.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("关键帧")
                    .font(.headline)
                Text("\(core.chapterTimes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $core.loopChapters) {
                    Label("区间循环", systemImage: "repeat")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            Text("播放到想标记的位置按 +（⌘A），之后可用 ⌘N / ⌘P 快速跳转")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("还没有关键帧")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        List {
            ForEach(Array(core.chapterTimes.enumerated()), id: \.offset) { index, time in
                HStack {
                    Text("#\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    Button {
                        core.seek(toChapter: time)
                    } label: {
                        Text(core.format(Double(time)))
                            .font(.system(.body, design: .monospaced))
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button {
                        core.seek(toChapter: time)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                core.addChapter()
            } label: {
                Label("添加", systemImage: "plus")
            }
            Button {
                core.deleteChapter()
            } label: {
                Label("删除", systemImage: "minus")
            }
            Spacer()
            Menu {
                Button("导出关键帧…") { core.exportChapters() }
                Button("导入关键帧…") { core.importChapters() }
                Divider()
                Button("清空全部", role: .destructive) { core.removeAllChapters() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .controlSize(.small)
        .padding(8)
    }
}
