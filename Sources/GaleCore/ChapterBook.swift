import Foundation

/// 单个视频的关键帧集合。
///
/// 关键帧集合模型。
public struct ChapterBook: Codable, Equatable, Sendable {
    /// 视频的稳定标识（本地文件 → 路径+大小+修改时间的摘要）
    public var mediaKey: String
    /// 标题（用于导出/导入时辨认）
    public var title: String
    /// 关键帧时间点，单位秒，整数，始终升序 —— 与原实现一致
    public private(set) var times: [Int]

    public init(mediaKey: String, title: String = "", times: [Int] = []) {
        self.mediaKey = mediaKey
        self.title = title
        self.times = times.sorted()
    }

    public var isEmpty: Bool { times.isEmpty }
    public var count: Int { times.count }

    // MARK: - 核心算法（逐条对应原实现）

    /// 添加关键帧 —— 原 `addChapter`。
    /// `t = floor(当前时间)`；已存在相同时间点则忽略；否则插入并升序排序。
    /// - Returns: 实际写入的时间点；重复时返回 nil。
    @discardableResult
    public mutating func add(at seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let t = Int(floor(seconds))
        guard !times.contains(t) else { return nil }
        times.append(t)
        times.sort()
        return t
    }

    /// 删除关键帧 —— 原 `deleteChapter`。
    /// 删除「当前时间之前最近的一个」（即最后一个严格小于当前时间的），
    /// 并返回它的时间点（原实现会 seek 到该点）。
    @discardableResult
    public mutating func removeNearest(before seconds: Double) -> Int? {
        guard seconds.isFinite else { return nil }
        let t = Int(floor(seconds))
        var index = -1
        for (i, time) in times.enumerated() {
            if time >= t { break }
            index = i
        }
        guard index >= 0 else { return nil }
        let removed = times[index]
        times.remove(at: index)
        return removed
    }

    /// 下一个关键帧 —— 原 `skipNextChapter`：第一个严格大于当前时间的。
    public func next(after seconds: Double) -> Int? {
        times.first { Double($0) > seconds }
    }

    /// 上一个关键帧 —— 原 `skipPreviousChapter`：逆序找第一个满足
    /// `time + 1 < 当前时间` 的（原实现的 1 秒保护，避免跳回当前所在点）。
    public func previous(before seconds: Double) -> Int? {
        for time in times.reversed() where Double(time) + 1 < seconds {
            return time
        }
        return nil
    }

    /// A-B 循环区间 —— 原 `repeat_chapter`：返回当前所处的 `[起点, 终点)` 区间。
    /// 播放跨过终点时回到起点。
    public func loopRange(at seconds: Double) -> ClosedRange<Double>? {
        guard times.count >= 2 else { return nil }
        var start: Int?
        for time in times where Double(time) <= seconds {
            start = time
        }
        guard let start, let idx = times.firstIndex(of: start), idx + 1 < times.count else {
            return nil
        }
        return Double(start)...Double(times[idx + 1])
    }

    public mutating func removeAll() {
        times.removeAll()
    }

    // MARK: - 导入 / 导出（原 chapter_export / chapter_import）

    /// 导出为可交换的 JSON 文件内容。
    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// 从导出文件恢复。校验：文件损坏 → nil；内容为空 → nil（对应原版
    /// `chapter_import_invalid` / `chapter_import_empty` 两种错误）。
    public static func importBook(from data: Data, mediaKey: String) throws -> ChapterBook {
        guard let decoded = try? JSONDecoder().decode(ChapterBook.self, from: data) else {
            throw ChapterImportError.invalid
        }
        guard !decoded.times.isEmpty else {
            throw ChapterImportError.empty
        }
        var book = decoded
        book.mediaKey = mediaKey
        book.times = decoded.times.sorted()
        return book
    }
}

public enum ChapterImportError: Error, LocalizedError {
    case invalid
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalid: "关键帧文件已损坏，无法读取"
        case .empty: "关键帧文件是空的"
        }
    }
}
