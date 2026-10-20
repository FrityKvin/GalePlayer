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
            Text("\(settings.orderedMedia.count)")
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
                ForEach(settings.playlistItems) { node in
                    PlaylistRow(
                        node: node,
                        imageMode: settings.imageMode,
                        selection: $selection,
                        onToggleFavorite: { settings.toggleFavorite([$0]) },
                        isCurrent: isCurrent(node),
                        expandedFolders: $expandedFolders,
                        playingURL: core.currentURL
                    )
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
                if let first = ids.first, let node = find(first, in: settings.playlistItems) {
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
        let target = path(of: current)

        func owner(_ nodes: [PlaylistNode]) -> PlaylistNode.ID? {
            for node in nodes {
                if node.resolvedIsFolder {
                    if node.flattenedMedia.contains(where: { path(of: $0.url) == target }) {
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
    private func isCurrent(_ node: PlaylistNode) -> Bool {
        PlaylistRow.isCurrent(node, playing: core.currentURL)
    }

    private func find(_ id: UUID, in nodes: [PlaylistNode]) -> PlaylistNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children, let hit = find(id, in: children) { return hit }
        }
        return nil
    }
}

private struct PlaylistRow: View {
    /// 「这一行是不是正在播放」的**唯一**判定。
    ///
    /// 放在类型上而不是只放在 PlaylistPanel，是为了文件夹子项也能各自判断 ——
    /// 递归时若把父级（文件夹，恒为 false）的结果透传下去，所有子项就永远不高亮。
    static func isCurrent(_ node: PlaylistNode, playing current: URL?) -> Bool {
        guard let current, !node.resolvedIsFolder else { return false }
        return current.resolvingSymlinksInPath().standardizedFileURL.path
            == node.url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    let node: PlaylistNode
    let imageMode: Bool
    @Binding var selection: PlaylistNode.ID?
    /// 切换星标；文件夹节点传 nil 表示不提供（避免整目录误标）。
    var onToggleFavorite: ((PlaylistNode.ID) -> Void)?
    /// 是否正在播放（高亮用）
    var isCurrent: Bool = false
    /// 所属面板的「自动展开」集合（文件夹行用它决定自己是否展开）
    @Binding var expandedFolders: Set<PlaylistNode.ID>
    /// 当前正在播放的 URL（逐行判定高亮用）
    let playingURL: URL?

    var body: some View {
        if node.resolvedIsFolder, let children = node.children {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedFolders.contains(node.id) },
                set: { isOn in
                    if isOn { expandedFolders.insert(node.id) } else { expandedFolders.remove(node.id) }
                }
            )) {
                ForEach(children) { child in
                    PlaylistRow(
                        node: child,
                        imageMode: imageMode,
                        selection: $selection,
                        onToggleFavorite: onToggleFavorite,
                        // 必须**逐节点**判断，不能把父级的 isCurrent 透传下去：
                        // 父级是文件夹，其 isCurrent 恒为 false，
                        // 透传会让所有子项永远不高亮（这正是「文件夹内不高亮」的根因）。
                        isCurrent: Self.isCurrent(child, playing: playingURL),
                        expandedFolders: $expandedFolders,
                        playingURL: playingURL
                    )
                }
            } label: {
                rowLabel
            }
        } else {
            rowLabel.tag(node.id)
        }
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
        .listRowBackground(
            isCurrent && !node.resolvedIsFolder
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
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
