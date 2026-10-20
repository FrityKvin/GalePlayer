import Foundation

/// 播放列表导入 —— 与 `PlaylistExporter` 配对，构成导出/导入闭环。
///
/// 需求背景（Kevin 2026-10）：导出文件**只需要 Gale 自己能用**，所以格式以
/// 「能被原样读回」为准，而不是通用性。为此导入要还原三样东西：
/// 1. 文件夹层级（`PlaylistNode` 树）
/// 2. 星标
/// 3. 每个视频的关键帧位置
///
/// 关键帧的存放有个约束：内部按 `MediaKey`（路径+大小+修改时间的摘要）索引，
/// 而导出文件里保存的是**路径**。所以解析结果里关键帧按路径给出，
/// 由上层（`PlayerCore`）在确认文件存在后换算成 `MediaKey` 再写回 `ChapterStore`。
public struct PlaylistImportResult: Sendable {
    /// 还原出的播放列表（含文件夹层级与星标）
    public var items: [PlaylistNode]
    /// 关键帧：路径 → 升序的秒数
    public var chaptersByPath: [String: [Int]]

    public init(items: [PlaylistNode], chaptersByPath: [String: [Int]]) {
        self.items = items
        self.chaptersByPath = chaptersByPath
    }

    /// 媒体项总数（不含文件夹节点）
    public var mediaCount: Int { items.reduce(0) { $0 + $1.flattenedMedia.count } }
    /// 有关键帧记录的媒体项数
    public var chapterItemCount: Int {
        items.reduce(0) { partial, node in
            partial + node.flattenedMedia.filter { chaptersByPath[$0.url.path] != nil }.count
        }
    }
    /// 关键帧总个数
    public var chapterCount: Int { chaptersByPath.values.reduce(0) { $0 + $1.count } }
}

public enum PlaylistImportError: Error, LocalizedError {
    case notGalePlaylist
    case unsupportedVersion(Int)
    case broken

    public var errorDescription: String? {
        switch self {
        case .notGalePlaylist: "这不是 Gale 导出的播放列表文件"
        case .unsupportedVersion(let version): "播放列表文件版本过新（v\(version)），请更新 Gale"
        case .broken: "播放列表文件已损坏，无法读取"
        }
    }
}

public enum PlaylistImporter {

    /// 解析 Gale 原生播放列表文件内容。
    ///
    /// - Throws: `PlaylistImportError`（不是本 App 的文件 / 版本不支持 / 结构损坏）
    public static func parse(data: Data) throws -> PlaylistImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaylistImportError.broken
        }
        // 兼容旧名字导出的文件：改名前的标识符是 "zephyr-playlist"，
        // 这里一并接受，否则用户此前导出的播放列表会报"不是本 App 的文件"。
        let acceptedFormats: Set<String> = ["gale-player-playlist", "zephyr-playlist"]
        guard let format = root["format"] as? String, acceptedFormats.contains(format) else {
            throw PlaylistImportError.notGalePlaylist
        }
        let version = root["version"] as? Int ?? 1
        guard version <= 1 else { throw PlaylistImportError.unsupportedVersion(version) }

        guard let rawItems = root["items"] as? [[String: Any]] else {
            throw PlaylistImportError.broken
        }

        var chapters: [String: [Int]] = [:]

        func build(_ raw: [String: Any]) -> PlaylistNode {
            let path = raw["path"] as? String ?? ""
            let url = URL(fileURLWithPath: path)
            if let times = raw["chapters"] as? [Int], !times.isEmpty {
                chapters[url.path] = times.sorted()
            }
            let children = (raw["children"] as? [[String: Any]])?.map(build)
            return PlaylistNode(
                name: raw["name"] as? String ?? url.lastPathComponent,
                url: url,
                isFolder: raw["isFolder"] as? Bool ?? false,
                children: children,
                isFavorite: raw["isFavorite"] as? Bool ?? false
            )
        }

        let items = rawItems.map(build)
        return PlaylistImportResult(items: items, chaptersByPath: chapters)
    }

    /// 解析文件内容（便捷入口）。
    public static func parse(contentsOf url: URL) throws -> PlaylistImportResult {
        try parse(data: try Data(contentsOf: url))
    }
}