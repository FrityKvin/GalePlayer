import Foundation

/// 缺失文件判定（纯逻辑，可单测）。
///
/// 背景：文件从磁盘被删后，播放列表条目仍在。播放器曾因此卡死——
/// 无推进、无标记、无提示。修复把「哪些路径算缺失」抽成纯函数：
/// 判定逻辑在 Core 层可测，文件系统调用由调用方注入。
///
/// 语义约定：
/// - 「缺失」是**文件系统事实**，不落盘进 playlist.json——文件恢复/改名回来后
///   下一次全表刷新就自动摘掉标记，不需要迁移数据。
/// - 路径一律用 `Playlist.canonical` 归一化后的 `.path`（与高亮判定同一约定）。
public enum MissingFiles {

    /// 从一组媒体路径里挑出「谓词判定不存在」的那些。
    ///
    /// - Parameter paths: 已规范化的媒体路径集合。
    /// - Parameter fileExists: 谓词。测试注入假谓词；生产传
    ///   `FileManager.default.fileExists(atPath:)`。
    public static func missing(
        in paths: [String],
        fileExists: (String) -> Bool
    ) -> Set<String> {
        var missing: Set<String> = []
        for path in paths where !fileExists(path) {
            missing.insert(path)
        }
        return missing
    }

    /// 从播放列表节点树取出**媒体文件**的路径（文件夹自身不算）。
    ///
    /// 供 AppSettings 在启动/导入/追加后做一次全表刷新；
    /// `flattenedMedia` 已经是深度优先的播放顺序，直接取它的 URL。
    public static func mediaPaths(from nodes: [PlaylistNode]) -> [String] {
        nodes.flatMap(\.flattenedMedia).map(\.url.path)
    }
}
