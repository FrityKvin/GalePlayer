import XCTest
@testable import GaleCore

/// 跨实例关键帧合并（多开播放器时的写入正确性）。
///
/// 背景：多开实例共享 chapters.json，写入是「全量覆写整个文件」。
/// 实例 A 加了 5 个关键帧、实例 B 同时加 1 个 → B 的覆写把 A 的 5 个抹掉。
/// 修复后的写入契约：**拿锁 → 重读磁盘 → 只合并自己改的那一个 mediaKey → 写 → 释放**。
///
/// 关键帧天然可按键合并（`{mediaKey: ChapterBook}`），所以合并粒度就是 mediaKey。
final class ChapterStoreMergeTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-chaptermerge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 核心场景：两个「实例」（两个 ChapterStore 对象，模拟两个进程各持一份内存副本）
    /// 各改不同 mediaKey，第二个写盘不得抹掉第一个的改动。
    func testConcurrentWritesToDifferentMediaKeysBothSurvive() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 两个实例共享同一个目录 = 两个进程共享同一份 chapters.json
        let instanceA = ChapterStore(directory: dir)
        let instanceB = ChapterStore(directory: dir)

        // A 改 mediaKey "filmA"
        var bookA = ChapterBook(mediaKey: "filmA", title: "影片A")
        bookA.add(at: 100)
        bookA.add(at: 200)
        instanceA.update(bookA)

        // B 改 mediaKey "filmB"（B 的内存副本里没有 filmA）
        var bookB = ChapterBook(mediaKey: "filmB", title: "影片B")
        bookB.add(at: 300)
        instanceB.update(bookB)

        // 磁盘上的最终状态必须**两个都在**
        let reopened = ChapterStore(directory: dir)
        XCTAssertEqual(reopened.book(for: "filmA")?.times, [100, 200], "A 的关键帧被 B 的写入抹掉了")
        XCTAssertEqual(reopened.book(for: "filmB")?.times, [300], "B 的关键帧应存在")
        XCTAssertEqual(reopened.allBooks().count, 2)
    }

    /// 同一 mediaKey 的并发修改：写方赢自己那条，但不得丢失「自己没碰过」的其他 key。
    func testConcurrentWriteSameKeyPlusOtherKeysKept() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let instanceA = ChapterStore(directory: dir)
        var base = ChapterBook(mediaKey: "shared", title: "共享")
        base.add(at: 10)
        instanceA.update(base)

        let instanceB = ChapterStore(directory: dir)   // B 启动时读到 shared=[10]
        // A 之后又给 shared 加了 20（B 不知道）
        var updated = ChapterBook(mediaKey: "shared", title: "共享")
        updated.add(at: 10)
        updated.add(at: 20)
        instanceA.update(updated)
        // B 改另一个文件
        var other = ChapterBook(mediaKey: "other", title: "别的")
        other.add(at: 55)
        instanceB.update(other)

        let reopened = ChapterStore(directory: dir)
        XCTAssertEqual(reopened.book(for: "shared")?.times, [10, 20], "A 对 shared 的最新改动必须保留")
        XCTAssertEqual(reopened.book(for: "other")?.times, [55])
    }

    /// 删除语义：某实例删掉一个 book（空集合），不得把别的实例刚加的其他 book 带走。
    func testRemovalDoesNotDropOtherInstancesBooks() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let instanceA = ChapterStore(directory: dir)
        instanceA.update(ChapterBook(mediaKey: "toDelete", title: "删我", times: [5]))

        let instanceB = ChapterStore(directory: dir)   // 此时读到 toDelete
        instanceB.update(ChapterBook(mediaKey: "keep", title: "留我", times: [7]))

        // A 删掉 toDelete（空 book = 删除）
        instanceA.update(ChapterBook(mediaKey: "toDelete", title: "删我", times: []))

        let reopened = ChapterStore(directory: dir)
        XCTAssertNil(reopened.book(for: "toDelete"), "空集合必须真的从磁盘移除")
        XCTAssertEqual(reopened.book(for: "keep")?.times, [7], "别的实例刚加的 book 不能被带走")
    }

    /// 合并不得破坏本实例之外的数据：三个实例各写一条，最终三条都在。
    func testThreeInstancesAllSurvive() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = ChapterStore(directory: dir)
        let b = ChapterStore(directory: dir)
        let c = ChapterStore(directory: dir)

        a.update(ChapterBook(mediaKey: "k1", title: "1", times: [1]))
        b.update(ChapterBook(mediaKey: "k2", title: "2", times: [2]))
        c.update(ChapterBook(mediaKey: "k3", title: "3", times: [3]))

        let reopened = ChapterStore(directory: dir)
        XCTAssertEqual(Set(reopened.allBooks().map(\.mediaKey)), ["k1", "k2", "k3"])
    }

    /// 性能门禁：大合并路径不得退化。500 个 book × 50 个关键帧的写合并要在预算内完成，
    /// 且合并后内容完整（Kevin 点名：不能因为数据量大被卡死）。
    func testLargeMergeStaysWithinBudget() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 先灌入 500 个 book（每个 50 个关键帧）作为既有数据
        let seed = ChapterStore(directory: dir)
        for i in 0..<500 {
            seed.update(ChapterBook(mediaKey: "bulk-\(i)", title: "t\(i)", times: Array(1...50)))
        }
        XCTAssertEqual(seed.allBooks().count, 500)

        // 新实例在这 500 条之上写 1 条 → 必须重读 500 条 + 合并 + 写回
        let writer = ChapterStore(directory: dir)
        let start = Date()
        writer.update(ChapterBook(mediaKey: "newcomer", title: "新", times: [999]))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.25,
                          "大合并必须快（500 条既有数据 + 1 条写入），实测 \(String(format: "%.1f", elapsed * 1000))ms")
        let reopened = ChapterStore(directory: dir)
        XCTAssertEqual(reopened.allBooks().count, 501, "合并后既有 500 条不能丢")
        XCTAssertEqual(reopened.book(for: "newcomer")?.times, [999])
    }
}
