import AppKit
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
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("com.kevin.galeplayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
