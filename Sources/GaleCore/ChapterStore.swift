import Foundation

/// 关键帧持久化。
///
/// 持久化为 JSON（按 mediaKey 归档）：
///   `~/Library/Application Support/<bundle-id>/chapters.json`
/// 结构：`{ "<mediaKey>": ChapterBook }`，与原名值对语义一致。
///
/// ## 多开实例的写入正确性（2026-11）
///
/// 多开播放器 = 多个独立进程共享这一个文件。旧实现每次改动都**全量覆写**整个
/// 文件，于是「最后写的赢」：实例 A 加了 5 个关键帧、实例 B 同时加 1 个，
/// B 的覆写会把 A 的 5 个抹掉。
///
/// 现在的写入契约（`saveMerging`）：
///   1. 拿 `chapters.json.lock` 排他锁；
///   2. **重读磁盘**拿到别的实例可能刚写的最新状态；
///   3. 只覆盖自己这次改动的那**一个** mediaKey，其余 key 原样保留；
///   4. 写回（atomic），释放锁。
///
/// 为什么这个合并代价可控：关键帧是 `{mediaKey: book}` 字典，合并只需在字典上
/// 赋值一个 key —— 不需要逐条比较、不需要 diff 树。整文件重读+重编码是唯一成本，
/// 用下面的「磁盘签名快速通道」压住：串行写入（绝大多数情况）磁盘没变就不重读。
public final class ChapterStore: @unchecked Sendable {
    private let fileURL: URL
    private let lockURL: URL
    private let lock = NSLock()
    private var books: [String: ChapterBook] = [:]

    /// 上次成功写入/读取后看到的文件 size+mtime，用来判断「磁盘没变就跳过重读」。
    ///
    /// 这是本类最重要的性能优化：多实例绝大多数写入是**串行**的（用户不会真的
    /// 同时按两次 ⌘A），磁盘没变时省掉一次整文件解析。
    private var lastKnownSignature: FileSignature?

    private struct FileSignature: Equatable {
        let size: Int
        let modified: TimeInterval
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("chapters.json")
        self.lockURL = directory.appendingPathComponent("chapters.json.lock")
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

    /// 写入一个关键帧集合（空集合 = 删除该 mediaKey）。
    ///
    /// 关键：这不是「整文件覆写」，而是「只覆盖 mediaKey 这一个键」的合并写。
    public func update(_ book: ChapterBook) {
        // 内存侧：本实例视角立即可见
        lock.lock()
        if book.isEmpty {
            books.removeValue(forKey: book.mediaKey)
        } else {
            books[book.mediaKey] = book
        }
        lock.unlock()

        saveMerging(changedKey: book.mediaKey, value: book.isEmpty ? nil : book)
    }

    public func remove(mediaKey: String) {
        lock.lock()
        books.removeValue(forKey: mediaKey)
        lock.unlock()
        saveMerging(changedKey: mediaKey, value: nil)
    }

    // MARK: - 磁盘读

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: ChapterBook].self, from: data) else {
            return
        }
        lock.lock()
        books = decoded
        lock.unlock()
        lastKnownSignature = Self.signature(of: fileURL)
    }

    private static func signature(of url: URL) -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return FileSignature(size: size, modified: modified.timeIntervalSince1970)
    }

    // MARK: - 磁盘写（合并）

    /// 合并写：只把 `changedKey` 这一个键覆盖到磁盘上的最新状态。
    ///
    /// - Parameters:
    ///   - changedKey: 本次改动涉及的 mediaKey（**唯一**合并粒度）。
    ///   - value: 新的 book；nil 表示删除该 key。
    private func saveMerging(changedKey: String, value: ChapterBook?) {
        _ = FileLock.withLock(lockURL.path) {
            // ① 磁盘状态若未变化（size+mtime 相同），无需重读 —— 直接用自己的内存副本。
            //    这是「串行写入」路径的快速通道，避免每次写都白解析一遍大文件。
            let diskSignature = Self.signature(of: fileURL)
            var base: [String: ChapterBook]
            if let diskSignature, diskSignature == lastKnownSignature {
                lock.lock()
                base = books
                lock.unlock()
            } else {
                // ② 磁盘变了（别的实例写过）：重读，以磁盘为准
                base = Self.readFromDisk(fileURL) ?? {
                    lock.lock(); defer { lock.unlock() }
                    return books
                }()
            }

            // ③ 只覆盖自己改动的那一个键 —— 别的 key 一个都不动
            if let value {
                base[changedKey] = value
            } else {
                base.removeValue(forKey: changedKey)
            }

            // ④ 写回 + 更新本实例的内存副本与签名
            let wrote = Self.writeToDisk(base, url: fileURL)
            lock.lock()
            books = base
            lock.unlock()
            if wrote {
                lastKnownSignature = Self.signature(of: fileURL)
            }
        }
    }

    private static func readFromDisk(_ url: URL) -> [String: ChapterBook]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: ChapterBook].self, from: data)
    }

    @discardableResult
    private static func writeToDisk(_ books: [String: ChapterBook], url: URL) -> Bool {
        guard let data = try? JSONEncoder.sorted.encode(books) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
