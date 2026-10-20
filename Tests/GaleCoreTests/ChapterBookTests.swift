import XCTest
@testable import GaleCore

/// 关键帧算法测试。
///
/// 用例逐条对应 DMM Player 反编译出的原实现行为（见逆向报告 2.3 节）：
/// addChapter / deleteChapter / skipNextChapter / skipPreviousChapter / repeat_chapter。
final class ChapterBookTests: XCTestCase {
    private func book(_ times: [Int]) -> ChapterBook {
        ChapterBook(mediaKey: "k", title: "t", times: times)
    }

    // MARK: - add

    func testAddUsesFloorAndKeepsAscendingOrder() {
        var b = book([10, 30])
        XCTAssertEqual(b.add(at: 20.9), 20)
        XCTAssertEqual(b.times, [10, 20, 30], "添加后必须升序 —— 原实现 push + sort")
    }

    func testAddRejectsDuplicate() {
        var b = book([10])
        XCTAssertNil(b.add(at: 10.4), "floor 后与已有值相同应被忽略，返回 nil")
        XCTAssertEqual(b.times, [10])
    }

    func testAddRejectsNegativeAndNaN() {
        var b = book([])
        XCTAssertNil(b.add(at: -1))
        XCTAssertNil(b.add(at: .nan))
        XCTAssertTrue(b.isEmpty)
    }

    func testAddAllowsSameSecondDifferentFraction() {
        var b = book([])
        XCTAssertEqual(b.add(at: 5.1), 5)
        XCTAssertNil(b.add(at: 5.9), "同一秒内算同一个关键帧")
    }

    // MARK: - delete

    func testDeleteRemovesLargestTimeStrictlyBeforeCurrent() {
        var b = book([10, 20, 30])
        XCTAssertEqual(b.removeNearest(before: 25), 20, "删的是 25 之前最近的一个，不是 30")
        XCTAssertEqual(b.times, [10, 30])
    }

    func testDeleteDoesNotRemoveTimeEqualToCurrent() {
        var b = book([10, 20])
        XCTAssertEqual(b.removeNearest(before: 20), 10, "等于当前时间的那个不算「之前」")
        XCTAssertEqual(b.times, [20])
    }

    func testDeleteReturnsNilWhenNothingBefore() {
        var b = book([30, 40])
        XCTAssertNil(b.removeNearest(before: 5))
        XCTAssertEqual(b.times, [30, 40])
    }

    // MARK: - skip

    func testNextIsFirstStrictlyGreater() {
        let b = book([10, 20, 30])
        XCTAssertEqual(b.next(after: 20), 30, "恰好等于当前时间点不算「下一个」")
        XCTAssertEqual(b.next(after: 0), 10)
        XCTAssertNil(b.next(after: 30))
    }

    func testPreviousHasOneSecondGuard() {
        let b = book([10, 20])
        XCTAssertEqual(b.previous(before: 30), 20)
        XCTAssertEqual(b.previous(before: 21), 10, "20 + 1 < 21 不成立 → 回退到 10（原实现 1 秒保护）")
        XCTAssertNil(b.previous(before: 10.5), "10 + 1 < 10.5 不成立 → 无上一个")
    }

    // MARK: - A-B 循环

    func testLoopRangeCoversCurrentPosition() {
        let b = book([10, 20, 30])
        XCTAssertEqual(b.loopRange(at: 15), 10.0...20.0)
        XCTAssertEqual(b.loopRange(at: 25), 20.0...30.0)
        XCTAssertNil(b.loopRange(at: 35), "越过最后一个关键帧后没有可循环区间")
        XCTAssertNil(book([10]).loopRange(at: 10), "只有一个关键帧无法构成区间")
    }

    // MARK: - 导入导出

    func testExportImportRoundTrip() throws {
        let original = book([5, 15, 25])
        let data = try original.exportData()
        let restored = try ChapterBook.importBook(from: data, mediaKey: "newkey")
        XCTAssertEqual(restored.times, [5, 15, 25])
        XCTAssertEqual(restored.mediaKey, "newkey", "导入到当前视频时应改写 mediaKey")
    }

    func testImportRejectsBrokenAndEmptyFiles() throws {
        XCTAssertThrowsError(try ChapterBook.importBook(from: Data("not json".utf8), mediaKey: "k")) {
            XCTAssertEqual($0 as? ChapterImportError, .invalid)
        }
        let empty = try ChapterBook(mediaKey: "k", title: "", times: []).exportData()
        XCTAssertThrowsError(try ChapterBook.importBook(from: empty, mediaKey: "k")) {
            XCTAssertEqual($0 as? ChapterImportError, .empty)
        }
    }
}

/// 持久化测试。
final class ChapterStoreTests: XCTestCase {
    func testStorePersistsAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChapterStore(directory: directory)
        var b = ChapterBook(mediaKey: "abc", title: "影片")
        b.add(at: 60)
        b.add(at: 120)
        store.update(b)

        let reopened = ChapterStore(directory: directory)
        XCTAssertEqual(reopened.book(for: "abc")?.times, [60, 120])
    }

    func testStoreDropsEmptyBooks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ChapterStore(directory: directory)
        store.update(ChapterBook(mediaKey: "abc", title: "影片", times: [10]))
        store.update(ChapterBook(mediaKey: "abc", title: "影片", times: []))
        XCTAssertNil(store.book(for: "abc"), "空的关键帧集合不应留在磁盘上")
    }
}
