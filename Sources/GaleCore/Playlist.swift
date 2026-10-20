import Foundation

/// 播放列表节点。
///
/// 播放列表树（folder / mediaItem 两种节点）：
/// 树形，文件夹节点可展开，媒体项有序；支持图文两种呈现模式。
public struct PlaylistNode: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    public var isFolder: Bool
    public var children: [PlaylistNode]?
    /// 星标（收藏）：用户手动标记，跨会话保留；排序不因星标改变。
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        isFolder: Bool,
        children: [PlaylistNode]? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isFolder = isFolder
        self.children = children
        self.isFavorite = isFavorite
    }

    /// 自定义 Codable：老版本落盘的 `playlist.json` 没有 `isFavorite` 字段，
    /// 用合成解码会直接 keyNotFound 抛错，导致用户的列表整个读不出来。
    private enum CodingKeys: String, CodingKey {
        case id, name, url, isFolder, children, isFavorite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        isFolder = try container.decode(Bool.self, forKey: .isFolder)
        children = try container.decodeIfPresent([PlaylistNode].self, forKey: .children)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isFolder, forKey: .isFolder)
        try container.encodeIfPresent(children, forKey: .children)
        try container.encode(isFavorite, forKey: .isFavorite)
    }

    /// 文件夹节点若所有子项都是文件夹，仍按文件夹展示。
    public var resolvedIsFolder: Bool { isFolder || children != nil }

    /// 深度优先展开出所有媒体文件（播放顺序）。
    public var flattenedMedia: [PlaylistNode] {
        guard let children, !children.isEmpty else {
            return isFolder ? [] : [self]
        }
        return children.flatMap(\.flattenedMedia)
    }
}

/// 播放列表管理。
///
/// 列表行为细节：
/// 文件夹批量导入 + 自然序排列（原版曾因乱序被用户投诉）、退出保存、
/// 打开时清空、最近播放列表、图文/文字双视图偏好。
public final class Playlist: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Storage()
    private let fileURL: URL
    private let imageModeKey = "playlistImageMode"

    public struct Storage: Codable, Sendable {
        public var items: [PlaylistNode] = []
        public var recents: [URL] = []
        /// 退出时清空列表
        public var clearOnExit: Bool = false
        /// 打开文件时清空列表
        public var clearOnOpen: Bool = false
        /// 播放列表自动隐藏秒数（0 = 不自动隐藏），对应原版 autoHidePlaylistTime
        public var autoHideSeconds: Double = 3
        public var imageMode: Bool = false
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("playlist.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 读取

    public var items: [PlaylistNode] {
        lock.lock(); defer { lock.unlock() }
        return storage.items
    }

    public var recents: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage.recents
    }

    public var settings: Storage {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public var imageMode: Bool {
        get { settings.imageMode }
        set { mutate { $0.imageMode = newValue } }
    }

    // MARK: - 设置写入
    // `settings` 返回的是值拷贝，调用方无法就地修改；因此提供显式 setter，
    // 保证核心层自身的 prepareForExit() 等行为可以被正确配置。

    public func setClearOnExit(_ value: Bool) {
        mutate { $0.clearOnExit = value }
    }

    public func setClearOnOpen(_ value: Bool) {
        mutate { $0.clearOnOpen = value }
    }

    /// 播放列表自动隐藏秒数（原版 `setAutoHidePlaylistTime:`）；0 = 不自动隐藏。
    public func setAutoHideSeconds(_ seconds: Double) {
        mutate { $0.autoHideSeconds = max(0, seconds) }
    }

    /// 按播放顺序展开的媒体项。
    public var orderedMedia: [PlaylistNode] {
        items.flatMap(\.flattenedMedia)
    }

    // MARK: - 写入

    /// 添加媒体文件。
    /// - Parameter clearExisting: `nil`（默认）时遵循 `clearOnOpen` 设置；
    ///   显式传入则覆盖设置。
    public func add(files urls: [URL], clearExisting: Bool? = nil) {
        mutate { storage in
            if clearExisting ?? storage.clearOnOpen { storage.items.removeAll() }
            let nodes = Self.mediaNodes(from: urls)
            storage.items.append(contentsOf: Self.droppingDuplicates(nodes, in: storage.items))
        }
    }

    /// 去掉「已经在列表里的」那些项。
    ///
    /// 不去重的话，同一个文件被反复加入会出现多个节点，
    /// 而播放列表的「正在播放高亮」是**按路径匹配**的，
    /// 结果同一个文件的所有副本一起高亮（实测自检命中 3/9）。
    /// 同一路径只保留最先出现的那一个。
    static func droppingDuplicates(_ newNodes: [PlaylistNode], in existing: [PlaylistNode]) -> [PlaylistNode] {
        // 先收集「已有」的路径：新节点与它们比对
        var seen = Set<String>()
        for node in existing {
            // 文件夹只登记它的**媒体子项**；把文件夹自身路径也登记进来的话，
            // 从同一个目录里再加一次文件夹会被整项丢弃（应该去重，但要用下面
            // 单独的「文件夹路径」集合来判，不能混入媒体集合）。
            for item in node.flattenedMedia {
                seen.insert(Self.normalizedKey(item.url))
            }
        }
        var seenFolders = Set<String>()
        for node in existing where node.resolvedIsFolder {
            seenFolders.insert(Self.normalizedKey(node.url))
        }

        var result: [PlaylistNode] = []
        for node in newNodes {
            if node.resolvedIsFolder {
                // 先按文件夹路径去重：同一目录重复拖入不该出现第二个 toggle
                if !seenFolders.insert(Self.normalizedKey(node.url)).inserted { continue }
                // 文件夹节点：只要内部还有未出现过的媒体文件就整项保留，
                // 否则整项丢弃（全部重复时不必留下一个空的 toggle）。
                let children = node.flattenedMedia
                let hasNew = children.contains { seen.insert(Self.normalizedKey($0.url)).inserted }
                if hasNew { result.append(node) }
            } else {
                if seen.insert(Self.normalizedKey(node.url)).inserted {
                    result.append(node)
                }
            }
        }
        return result
    }

    /// 比对用的规范化路径键（符号链接 + 标准化）。
    private static func normalizedKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 打开文件夹 —— 原版 `creatElementsFromFolder:PLAYID:PARENTID:NEXTID:`。
    ///
    /// 交互约定（Kevin 2026-10 确认）：拖入哪个文件夹，就只出现**这一个** toggle；
    /// 其子项为该文件夹下**递归**扫描出的全部媒体文件（扁平一层，子文件夹
    /// 不再各自成为节点），整体按相对路径自然序排列。
    public func add(folder url: URL, clearExisting: Bool? = nil) {
        let node = Self.folderNode(for: url)
        mutate { storage in
            if clearExisting ?? storage.clearOnOpen { storage.items.removeAll() }
            // 同样要去重：同一目录重复拖入不该出现第二个 toggle，
            // 也不该让展开后的媒体项翻倍（否则高亮会按路径命中多行）。
            let fresh = Self.droppingDuplicates([node], in: storage.items)
            storage.items.append(contentsOf: fresh)
        }
    }

    /// 追加已构造好的节点树（导入用；不做文件系统扫描）。
    ///
    /// 同路径的已有项会被跳过：否则把同一份列表导入两次就变成双倍条目，
    /// 高亮也会跟着按路径一起亮。
    public func addNodes(_ nodes: [PlaylistNode]) {
        guard !nodes.isEmpty else { return }
        mutate { storage in
            storage.items.append(contentsOf: Self.droppingDuplicates(nodes, in: storage.items))
        }
    }

    /// 直接添加已构造好的节点树（导入 / 测试用；不做文件系统扫描）。
    public func add(nodes: [PlaylistNode], clearExisting: Bool? = nil) {
        mutate { storage in
            if clearExisting ?? storage.clearOnOpen { storage.items.removeAll() }
            storage.items.append(contentsOf: nodes)
        }
    }

    public func remove(ids: Set<UUID>) {
        mutate { storage in
            storage.items = Self.prune(storage.items, removing: ids)
        }
    }

    /// 设置/取消星标。星标只影响显示与筛选，**不改变列表顺序**。
    public func setFavorite(_ ids: Set<UUID>, to value: Bool) {
        guard !ids.isEmpty else { return }
        mutate { storage in
            storage.items = Self.marking(storage.items, ids: ids, favorite: value)
        }
    }

    /// 翻转星标（用于列表里的星号点击与右键菜单）。
    ///
    /// 语义与 Finder 的「添加到个人收藏」一致：**全部**已标则整体取消，否则整体标记。
    public func toggleFavorite(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let selected = flattened(items).filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let allStarred = selected.allSatisfy(\.isFavorite)
        setFavorite(ids, to: !allStarred)
    }

    /// 递归打星标（含文件夹下的所有媒体项）。
    private static func marking(_ items: [PlaylistNode], ids: Set<UUID>, favorite: Bool) -> [PlaylistNode] {
        items.map { node in
            var copy = node
            if ids.contains(node.id) { copy.isFavorite = favorite }
            if let children = node.children {
                copy.children = marking(children, ids: ids, favorite: favorite)
            }
            return copy
        }
    }

    private func flattened(_ items: [PlaylistNode]) -> [PlaylistNode] {
        items.flatMap { $0.flattenedMedia }
    }

    public func clear() {
        mutate { $0.items.removeAll() }
    }

    /// 移动/排序 —— 对应原版 `dragToPlayList:parentID:insertionIndex:meidaID:`。
    /// （不用 SwiftUI 的 `Array.move`，核心层保持仅依赖 Foundation）
    public func move(fromOffsets: IndexSet, toOffset: Int) {
        mutate { storage in
            storage.items = Self.reordered(storage.items, from: fromOffsets, to: toOffset)
        }
    }

    static func reordered<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let moving = source.sorted().map { items[$0] }
        var remaining = items
        for index in source.sorted(by: >) {
            remaining.remove(at: index)
        }
        let removedBefore = source.filter { $0 < destination }.count
        let insertion = min(max(0, destination - removedBefore), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        return remaining
    }

    public func recordRecent(_ url: URL, limit: Int = 20) {
        mutate { storage in
            storage.recents.removeAll { $0 == url }
            storage.recents.insert(url, at: 0)
            if storage.recents.count > limit {
                storage.recents = Array(storage.recents.prefix(limit))
            }
        }
    }

    public func clearRecents() {
        mutate { $0.recents.removeAll() }
    }

    // MARK: - 扫描与排序

    public static func mediaNodes(from urls: [URL]) -> [PlaylistNode] {
        urls
            .filter { MediaTypes.isSupported($0) }
            .map { PlaylistNode(name: $0.lastPathComponent, url: $0, isFolder: false) }
            .sorted { naturalCompare($0.name, $1.name) }
    }

    /// 文件夹节点：单个 toggle，children 为递归扫出的**扁平**媒体文件列表。
    public static func folderNode(for url: URL) -> PlaylistNode {
        PlaylistNode(
            name: url.lastPathComponent,
            url: url,
            isFolder: true,
            children: scanAllMedia(root: url)
        )
    }

    /// 递归收集 `root` 下所有支持的媒体文件（不产生中间文件夹节点），
    /// 按相对路径自然序排列（`第2集` 在 `第10集` 之前）。
    private static func scanAllMedia(root: URL) -> [PlaylistNode] {
        var collected: [(node: PlaylistNode, path: String)] = []

        func walk(_ directory: URL, prefix: String) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for entry in entries {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    walk(entry, prefix: prefix + entry.lastPathComponent + "/")
                } else if MediaTypes.isSupported(entry) {
                    collected.append((
                        PlaylistNode(name: entry.lastPathComponent, url: entry, isFolder: false),
                        prefix + entry.lastPathComponent
                    ))
                }
            }
        }

        walk(root, prefix: "")
        return collected
            .sorted { naturalCompare($0.path, $1.path) }
            .map(\.node)
    }

    private static func prune(_ nodes: [PlaylistNode], removing ids: Set<UUID>) -> [PlaylistNode] {
        nodes.compactMap { node in
            if ids.contains(node.id) { return nil }
            var copy = node
            if let children = node.children {
                copy.children = prune(children, removing: ids)
            }
            return copy
        }
    }

    /// 自然序比较：`第2集` 排在 `第10集` 之前（原版曾被投诉的直接原因）。
    public static func naturalCompare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    // MARK: - 磁盘

    private func mutate(_ body: (inout Storage) -> Void) {
        lock.lock()
        body(&storage)
        let snapshot = storage
        lock.unlock()
        save(snapshot)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        lock.lock()
        storage = decoded
        lock.unlock()

        // 旧版本会把子文件夹也存成文件夹节点；这里统一压平成「单层 toggle」，
        // 否则升级后老用户的列表仍然显示嵌套层级。
        let normalized = decoded.items.map(Self.normalized)
        if normalized != decoded.items {
            mutate { $0.items = normalized }
        }
    }

    /// 把文件夹节点压平：children 只保留媒体文件（递归展开，见 `flattenedMedia`）。
    static func normalized(_ item: PlaylistNode) -> PlaylistNode {
        guard item.resolvedIsFolder else { return item }
        var copy = item
        copy.children = item.flattenedMedia
        return copy
    }

    private func save(_ snapshot: Storage) {
        guard let data = try? JSONEncoder.sorted.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 退出时按设置清空。
    public func prepareForExit() {
        let s = settings
        if s.clearOnExit {
            clear()
            clearRecents()
        }
    }
}
