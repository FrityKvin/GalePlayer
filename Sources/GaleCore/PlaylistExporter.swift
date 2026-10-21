import Foundation

/// 播放列表导出格式。
public enum PlaylistExportFormat: String, CaseIterable, Sendable {
    /// **Gale 原生格式（默认）**：保留文件夹层级、星标、每个文件的关键帧（整数秒），
    /// 可由 `PlaylistImporter` 原样读回 —— 导出/导入闭环，用于备份、换机、分享。
    case json
    /// 可选的纯列表（标准 M3U8）：关键帧与星标以 `#GALE-` 注释行携带。
    /// 不作为默认，因为需求明确「只要自家播放器能用」；保留给需要外部工具读列表的场景。
    case m3u8

    public var displayName: String {
        switch self {
        case .json: "Gale 播放列表（.json，可再导入）"
        case .m3u8: "M3U8 纯列表（.m3u8）"
        }
    }

    public var fileExtension: String { rawValue }

    /// 按文件名后缀判断格式；**默认 Gale 原生格式**（保证导出→导入闭环）。
    public static func inferred(from url: URL) -> PlaylistExportFormat {
        url.pathExtension.lowercased() == "m3u8" ? .m3u8 : .json
    }
}

/// 播放列表导出。
///
/// 需求（Kevin 2026-10）：导出的文件必须**带上关键帧的位置记录**。
/// 关键帧数据本身存在 `ChapterStore` 里（按 `MediaKey` 索引），导出时按
/// 「路径+大小+修改时间的摘要」逐项关联，因此即使列表里同一部片子换过路径，
/// 也能正确对应（这一点与内部存储保持一致）。
public enum PlaylistExporter {

    /// 导出入口。
    /// - Parameters:
    ///   - items: 播放列表顶层节点（含文件夹）
    ///   - books: 关键帧集合（任意数量，按 mediaKey 匹配）
    ///   - format: 输出格式
    ///   - exportedAt: 导出时间（便于单测固定）
    public static func export(
        items: [PlaylistNode],
        books: [ChapterBook],
        format: PlaylistExportFormat,
        exportedAt: Date = Date()
    ) -> Data {
        switch format {
        case .m3u8:
            Data(m3u8(items: items, books: books, exportedAt: exportedAt).utf8)
        case .json:
            (try? json(items: items, books: books, exportedAt: exportedAt)) ?? Data()
        }
    }

    /// 导出并同时返回计数 —— UI 要显示「共 N 项 / M 个关键帧」，
    /// 用这个就不必再额外调一次 `statistics`（那是又一遍 MediaKey）。
    public static func exportWithCounts(
        items: [PlaylistNode],
        books: [ChapterBook],
        format: PlaylistExportFormat,
        exportedAt: Date = Date()
    ) -> (data: Data, counts: Counts) {
        switch format {
        case .json:
            if let result = try? jsonWithCounts(items: items, books: books, exportedAt: exportedAt) {
                return result
            }
            return (Data(), Counts())
        case .m3u8:
            let (m, w, c, f) = statistics(items: items, books: books)
            let text = m3u8(items: items, books: books, exportedAt: exportedAt)
            return (Data(text.utf8), Counts(media: m, withChapters: w, chapters: c, favorites: f))
        }
    }

    /// 统计：媒体项数、含关键帧的项数、关键帧总数、星标项数。
    public static func statistics(items: [PlaylistNode], books: [ChapterBook]) -> (
        media: Int, withChapters: Int, chapters: Int, favorites: Int
    ) {
        let lookup = bookLookup(books)
        var media = 0, withChapters = 0, chapters = 0, favorites = 0
        for node in items.flatMap(\.flattenedMedia) {
            media += 1
            if node.isFavorite { favorites += 1 }
            // 没有关键帧时**完全不碰** MediaKey：它是 stat + SHA256，每项约 50µs，
            // 2000 项就是 100ms —— 而结果注定查不到东西。
            guard !lookup.isEmpty else { continue }
            guard let book = lookup[MediaKey.make(for: node.url)], !book.isEmpty else { continue }
            withChapters += 1
            chapters += book.count
        }
        return (media, withChapters, chapters, favorites)
    }

    // MARK: - M3U8

    public static func m3u8(items: [PlaylistNode], books: [ChapterBook], exportedAt: Date = Date()) -> String {
        let lookup = bookLookup(books)
        let stats = statistics(items: items, books: books)

        var lines: [String] = []
        lines.append("#EXTM3U")
        lines.append("# Gale 播放列表导出")
        lines.append("# 导出时间：\(timestamp(exportedAt))")
        lines.append("# 媒体 \(stats.media) 项 · 含关键帧 \(stats.withChapters) 项（共 \(stats.chapters) 个）· 星标 \(stats.favorites) 项")
        lines.append("#")
        lines.append("# 说明：本文件是标准 M3U8，其他播放器可直接打开；")
        lines.append("#       以 #GALE- 开头的注释行是 Gale 扩展，其他播放器会忽略。")
        lines.append("#       #GALE-CHAPTERS:H:MM:SS,...  该文件的关键帧位置（相对文件开头，升序）")
        lines.append("#       #GALE-FAVORITE:1           该文件在 Gale 里加了星标")
        lines.append("#")

        for node in items {
            if node.resolvedIsFolder {
                let children = node.flattenedMedia
                lines.append("#")
                lines.append("# 文件夹：\(node.name)（\(children.count) 项）")
                for child in children {
                    appendMedia(child, lookup: lookup, into: &lines)
                }
            } else {
                appendMedia(node, lookup: lookup, into: &lines)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendMedia(_ node: PlaylistNode, lookup: [String: ChapterBook], into lines: inout [String]) {
        // #EXTINF:-1,<标题> —— -1 表示时长未知（标准写法），播放器只看路径
        lines.append("#EXTINF:-1,\(node.name)")
        lines.append(node.url.path)
        if node.isFavorite {
            lines.append("#GALE-FAVORITE:1")
        }
        if let book = lookup[MediaKey.make(for: node.url)], !book.isEmpty {
            let stamps = book.times.map { timecode($0) }.joined(separator: ",")
            lines.append("#GALE-CHAPTERS:\(stamps)")
        }
    }

    // MARK: - JSON

    private struct ExportedPlaylist: Encodable {
        let format: String
        let version: Int
        let exportedAt: String
        let counts: Counts
        let items: [ExportedNode]

        struct Counts: Encodable {
            let media: Int
            let withChapters: Int
            let chapters: Int
            let favorites: Int
        }
    }

    private struct ExportedNode: Encodable {
        let name: String
        let path: String
        let isFolder: Bool
        let isFavorite: Bool
        /// 关键帧位置（整数秒，升序）—— 只在有记录时出现
        let chapters: [Int]?
        let children: [ExportedNode]?
    }

    /// 导出统计（避免调用方为了显示计数再跑一遍 MediaKey）。
    public struct Counts: Sendable, Equatable {
        public var media = 0
        public var withChapters = 0
        public var chapters = 0
        public var favorites = 0
        public init(media: Int = 0, withChapters: Int = 0, chapters: Int = 0, favorites: Int = 0) {
            self.media = media
            self.withChapters = withChapters
            self.chapters = chapters
            self.favorites = favorites
        }
    }

    public static func json(items: [PlaylistNode], books: [ChapterBook], exportedAt: Date = Date()) throws -> Data {
        try jsonWithCounts(items: items, books: books, exportedAt: exportedAt).data
    }

    /// JSON 导出主体：**一次遍历**同时产出字节与计数。
    public static func jsonWithCounts(
        items: [PlaylistNode], books: [ChapterBook], exportedAt: Date = Date()
    ) throws -> (data: Data, counts: Counts) {
        let lookup = bookLookup(books)
        // 计数在**同一次遍历**里累计，不再单独跑一遍 statistics：
        // 早先 statistics + convert 各算一次 MediaKey，PlayerCore 又先调了
        // 一次 statistics —— 同一批文件被 stat+SHA256 三遍（2000 项实测 292ms）。
        var media = 0, withChapters = 0, chapters = 0, favorites = 0

        func convert(_ node: PlaylistNode) -> ExportedNode {
            // 只在「有关键帧可匹配」时才付出 MediaKey 的代价
            var times: [Int]?
            if !lookup.isEmpty {
                if let book = lookup[MediaKey.make(for: node.url)], !book.isEmpty {
                    times = book.times
                }
            }
            if node.resolvedIsFolder {
                let children = (node.children ?? []).map(convert)
                return ExportedNode(name: node.name, path: node.url.path,
                                    isFolder: true, isFavorite: node.isFavorite,
                                    chapters: nil, children: children)
            }
            media += 1
            if node.isFavorite { favorites += 1 }
            if let times {
                withChapters += 1
                chapters += times.count
            }
            return ExportedNode(name: node.name, path: node.url.path,
                                isFolder: false, isFavorite: node.isFavorite,
                                chapters: times, children: nil)
        }

        let converted = items.map(convert)
        let payload = ExportedPlaylist(
            format: "gale-player-playlist",
            version: 1,
            exportedAt: isoTimestamp(exportedAt),
            counts: .init(
                media: media,
                withChapters: withChapters,
                chapters: chapters,
                favorites: favorites
            ),
            items: converted
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return (data, Counts(media: media, withChapters: withChapters,
                             chapters: chapters, favorites: favorites))
    }

    // MARK: - 工具

    /// mediaKey → ChapterBook（忽略空 book）
    private static func bookLookup(_ books: [ChapterBook]) -> [String: ChapterBook] {
        var lookup: [String: ChapterBook] = [:]
        for book in books where !book.isEmpty {
            lookup[book.mediaKey] = book
        }
        return lookup
    }

    /// 秒 → `H:MM:SS`（小时两位起）。
    public static func timecode(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}