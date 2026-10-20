import Foundation

/// 关键帧持久化。
///
/// 持久化为 JSON（按 mediaKey 归档）：
/// 本地播放器改为 Application Support 下的单个 JSON 文件：
///   `~/Library/Application Support/<bundle-id>/chapters.json`
/// 结构：`{ "<mediaKey>": ChapterBook }`，与原名值对语义一致。
public final class ChapterStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var books: [String: ChapterBook] = [:]

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("chapters.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    public func book(for mediaKey: String) -> ChapterBook? {
        lock.lock(); defer { lock.unlock() }
        return books[mediaKey]
    }

    public func allBooks() -> [ChapterBook] {
        lock.lock(); defer { lock.unlock() }
        return books.values.sorted { $0.mediaKey < $1.mediaKey }
    }

    public func update(_ book: ChapterBook) {
        lock.lock()
        if book.isEmpty {
            books.removeValue(forKey: book.mediaKey)
        } else {
            books[book.mediaKey] = book
        }
        lock.unlock()
        save()
    }

    public func remove(mediaKey: String) {
        lock.lock()
        books.removeValue(forKey: mediaKey)
        lock.unlock()
        save()
    }

    // MARK: - 磁盘

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: ChapterBook].self, from: data) else {
            return
        }
        lock.lock()
        books = decoded
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let snapshot = books
        lock.unlock()

        guard let data = try? JSONEncoder.sorted.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
