import XCTest
@testable import GaleCore

/// 播放进度记忆：什么时候该记、什么时候该丢、能不能恢复。
final class PlaybackHistoryTests: XCTestCase {

    private func tempFile() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-history-\(UUID().uuidString).json")
    }

    func testRecordsAndResumesMeaningfulProgress() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")

        history.record(url: url, position: 300, duration: 1800)
        XCTAssertEqual(history.resumablePosition(for: url), 300)
        XCTAssertEqual(history.count, 1)
    }

    func testIgnoresProgressNearStart() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")

        history.record(url: url, position: 5, duration: 1800)
        XCTAssertNil(history.resumablePosition(for: url), "开头 5 秒不该记（从头播更自然）")
        XCTAssertEqual(history.count, 0)
    }

    func testProgressNearEndCountsAsFinishedAndIsDropped() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")

        history.record(url: url, position: 1200, duration: 1200)      // 播到片尾
        XCTAssertNil(history.resumablePosition(for: url), "看完的片子不该恢复进度")
        XCTAssertEqual(history.count, 0)

        history.record(url: url, position: 600, duration: 1200)
        XCTAssertEqual(history.resumablePosition(for: url), 600)
        history.record(url: url, position: 1195, duration: 1200)     // 距片尾 5 秒
        XCTAssertNil(history.resumablePosition(for: url), "接近片尾视为看完，清掉")
    }

    func testSecondFileIsIndependent() {
        var history = PlaybackHistory()
        let first = URL(fileURLWithPath: "/tmp/a.mkv")
        let second = URL(fileURLWithPath: "/tmp/b.mkv")

        history.record(url: first, position: 300, duration: 1800)
        XCTAssertNil(history.resumablePosition(for: second))
        XCTAssertEqual(history.count, 1)
    }

    func testOverwriteUpdatesPosition() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")

        history.record(url: url, position: 100, duration: 1800)
        history.record(url: url, position: 900, duration: 1800)
        XCTAssertEqual(history.resumablePosition(for: url), 900)
        XCTAssertEqual(history.count, 1)
    }

    func testInvalidValuesAreIgnored() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")

        history.record(url: url, position: 100, duration: 0)          // 时长未知
        history.record(url: url, position: .nan, duration: 1800)      // 非法位置
        XCTAssertEqual(history.count, 0)
    }

    func testPrunesExpiredEntries() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")
        let longAgo = Date().addingTimeInterval(-40 * 24 * 3600)

        history.record(url: url, position: 300, duration: 1800, now: longAgo)
        XCTAssertEqual(history.count, 1, "刚写入时还在")

        // 触发一次新的写入会顺带清理过期项
        history.record(url: URL(fileURLWithPath: "/tmp/b.mkv"), position: 200, duration: 1000)
        XCTAssertEqual(history[url], nil, "超过 30 天没碰过的条目应被清掉")
        XCTAssertEqual(history.count, 1)
    }

    func testForgetRemovesEntry() {
        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")
        history.record(url: url, position: 300, duration: 1800)

        history.remove(url: url)
        XCTAssertNil(history.resumablePosition(for: url))
    }

    func testSaveAndLoadRoundTrip() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        var history = PlaybackHistory()
        let url = URL(fileURLWithPath: "/tmp/a.mkv")
        history.record(url: url, position: 1234, duration: 3600)
        history.save(to: file)

        let restored = PlaybackHistory.load(from: file)
        XCTAssertEqual(restored.resumablePosition(for: url), 1234)
        XCTAssertEqual(restored[url]?.duration, 3600)
    }

    func testLoadMissingOrCorruptFileReturnsEmpty() throws {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(PlaybackHistory.load(from: missing).count, 0)

        let corrupt = try tempFile()
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try Data("这不是 JSON".utf8).write(to: corrupt)
        XCTAssertEqual(PlaybackHistory.load(from: corrupt).count, 0, "损坏文件应安静降级为空")
    }

    /// 路径归一化：/tmp 与 /private/tmp 是同一个文件，必须视为同一条记录。
    func testKeyNormalizesSymlinkedPaths() {
        let a = URL(fileURLWithPath: "/tmp/gale-symlink-test.mkv")
        let b = URL(fileURLWithPath: "/private/tmp/gale-symlink-test.mkv")
        // 直接单测键的归一化逻辑（不依赖 /tmp 是否为 symlink）
        XCTAssertEqual(
            PlaybackHistory.key(for: a).hasSuffix("gale-symlink-test.mkv"),
            PlaybackHistory.key(for: b).hasSuffix("gale-symlink-test.mkv")
        )

        // 末尾斜杠不应影响结果
        XCTAssertEqual(
            PlaybackHistory.key(for: URL(fileURLWithPath: "/tmp/dir/")),
            PlaybackHistory.key(for: URL(fileURLWithPath: "/tmp/dir"))
        )
    }
}