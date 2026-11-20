import AppKit
import GaleCore
import QuickLookThumbnailing

/// 缩略图缓存：图文播放列表模式用（对应原版 `GenerateThumbnail:forPath:...`）。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var cache: [URL: NSImage] = [:]
    /// 缓存条目上限：图文模式的播放列表可能有几百项，
    /// 缩略图（160x90 TIFF 解码后约 100-200KB）无限增长会白吃掉几十 MB。
    private let cacheLimit = 120
    /// 简单的先进先出淘汰（够用：用户通常从头尾浏览）
    private var insertionOrder: [URL] = []

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }

        let data: Data? = await Task.detached(priority: .utility) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 160, height: 90),
                scale: 1,
                representationTypes: .thumbnail
            )
            guard let representation = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request) else { return nil }
            return representation.nsImage.tiffRepresentation
        }.value

        guard let data, let image = NSImage(data: data) else { return nil }
        store(url, image: image)
        return image
    }

    private func store(_ url: URL, image: NSImage) {
        cache[url] = image
        insertionOrder.append(url)
        while insertionOrder.count > cacheLimit {
            let evicted = insertionOrder.removeFirst()
            cache[evicted] = nil
        }
    }
}

/// 应用数据目录（关键帧 / 播放列表 / 设置）。
///
/// `active` 由 `GaleApp.init` 在启动时**一次性**写入（见 DataPaths）：
/// 普通启动 = Application Support 真实目录；自检 = 进程唯一的一次性临时目录。
/// 其他地方一律读 `AppPaths.active.directory`，不再自己去拼真实路径 ——
/// 这样「自检污染真实数据」这一类事故在结构上不可能再发生。
enum AppPaths {
    /// 当前进程的数据目录解析结果。由 GaleApp.init 写入；未初始化时按普通启动解析。
    nonisolated(unsafe) static var active: DataPaths.Resolved = DataPaths.resolve(
        arguments: CommandLine.arguments
    )

    /// 当前生效的数据目录。
    static var directory: URL { active.directory }

    /// 真实目录（仅用于「明确需要真实数据」的场景，例如迁移提示与文档）。
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent(DataPaths.realDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
