import Foundation

/// 播放进度记忆。
///
/// 设计要点：
///   - 键是**文件路径**（跨会话用），值是位置/时长/写入时间；
///   - 只有「有意义」的进度才记：开头 10 秒内、结尾 10 秒内（≈看完）、
///     以及超过 30 天没再碰过的条目都会被丢弃，避免列表无限增长；
///   - 纯 Foundation 实现，便于单测；App 侧由 PlayerCore 定时写入。
public struct PlaybackHistory: Codable, Equatable, Sendable {
    /// 单个文件的进度记录。
    public struct Entry: Codable, Equatable, Sendable {
        /// 播放位置（秒）
        public var position: Double
        /// 该媒体总时长（秒）；用于「是否已看完」的判断，避免依赖当前会话的 duration
        public var duration: Double
        /// 最后更新时间
        public var updatedAt: Date

        public init(position: Double, duration: Double, updatedAt: Date = Date()) {
            self.position = position
            self.duration = duration
            self.updatedAt = updatedAt
        }

        /// 是否已经看完（播到接近结尾）—— 这种进度不再值得恢复。
        public func isFinished(tolerance: Double = 10) -> Bool {
            duration > 0 && position >= duration - tolerance
        }
    }

    /// 路径 → 进度。JSON 对象里键就是路径字符串。
    public private(set) var entries: [String: Entry]

    /// 判定「值得恢复」的下限：开头这几秒直接从头播更自然。
    public var minimumResumePosition: Double = 10
    /// 过期天数
    public var expirationDays: Double = 30

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    // MARK: - 读写

    public static func load(from url: URL) -> PlaybackHistory {
        guard let data = try? Data(contentsOf: url) else { return PlaybackHistory() }
        let decoder = JSONDecoder()
        // 必须与 save() 的编码策略一致；不一致会让 updatedAt 解码失败，
        // 而整个文件被 `try?` 吞掉 → 表现为「进度莫名其妙全丢了」。
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(PlaybackHistory.self, from: data) else {
            return PlaybackHistory()
        }
        return decoded
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 记录

    /// 记录一次进度。会顺手清理无意义的条目。
    /// - Parameter url: 当前播放的文件
    public mutating func record(url: URL, position: Double, duration: Double, now: Date = Date()) {
        guard position.isFinite, duration.isFinite, duration > 0 else { return }
        let key = Self.key(for: url)
        // 开头：没必要记，直接从头播
        guard position >= minimumResumePosition else {
            entries.removeValue(forKey: key)
            return
        }
        // 结尾：视为看完，清掉这条，下次从头开始
        guard position < duration - 10 else {
            entries.removeValue(forKey: key)
            return
        }
        entries[key] = Entry(position: position, duration: duration, updatedAt: now)
        prune(now: now)
    }

    /// 清除某个文件的进度（用户主动从头播或删掉列表项时用）。
    public mutating func remove(url: URL) {
        entries.removeValue(forKey: Self.key(for: url))
    }

    /// 清理过期与已看完的条目。
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-expirationDays * 24 * 3600)
        entries = entries.filter { $0.value.updatedAt >= cutoff }
    }

    // MARK: - 查询

    /// 取某个文件「值得恢复」的进度；没有或已看完返回 nil。
    public func resumablePosition(for url: URL) -> Double? {
        guard let entry = entries[Self.key(for: url)] else { return nil }
        guard entry.position >= minimumResumePosition else { return nil }
        guard !entry.isFinished() else { return nil }
        return entry.position
    }

    public subscript(url: URL) -> Entry? { entries[Self.key(for: url)] }

    public var count: Int { entries.count }

    /// 统一的键：标准化的绝对路径（顺带解析 symlink，避免 /tmp 与 /private/tmp 不一致）。
    public static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}