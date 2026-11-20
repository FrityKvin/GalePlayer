import XCTest
@testable import GaleCore

/// 音量写入节流器：把「滑条每像素触发一次」合并成「最多每 N 毫秒写一次 mpv」。
///
/// 背景（实测数据，2026-11-20）：`mpv_set_property("volume")` 是同步阻塞调用，
/// 单次 10.4ms（p95 16ms）。SwiftUI Slider 拖动时每帧都可能回调，一次完整
/// 拖动（101 步）累计卡主线程 1263ms —— 用户感到「滞后、不跟手」。
///
/// 正确做法不是「每个事件都写」，而是：
///   - 拖动过程中按时间窗口节流（比如 60Hz 上限 = 16ms 一次）
///   - **最后一次值必须写**（否则松手后音量停在中途，用户会觉得"没调到"）→ trailing write
///   - 写入本身挪到后台线程，不阻塞主线程
final class ThrottlerTests: XCTestCase {

    /// 核心语义：高频调用被节流，但**最后的值一定送达**。
    func testThrottleCoalescesHighFrequencyCalls() {
        var written: [Int] = []
        let throttler = Throttler(interval: 0.05) { value in written.append(value) }

        // 模拟 100 次高频回调（每次间隔极小）
        for i in 0...100 {
            throttler.push(i)
        }
        // 拖动期间最多写几次由时间窗口决定；这里只断言「不是 101 次」
        XCTAssertLessThan(written.count, 101, "高频回调必须被合并（否则每次都写就是 101 次）")

        // 关键：把剩余值刷出去 —— 最后一次必须是 100
        throttler.flush()
        XCTAssertEqual(written.last, 100, "最后一次值必须送达（trailing write）")
    }

    /// 首次 push 立即生效（leading edge），窗口内的后续值被最新值覆盖。
    func testLatestValueWinsWithinWindow() {
        var written: [Int] = []
        let throttler = Throttler(interval: 0.1) { written.append($0) }
        throttler.push(1)          // 首个值立即写出（leading）
        throttler.push(2)          // 窗口内 → 只记录
        throttler.push(3)          // 窗口内 → 覆盖成 3
        throttler.flush()          // trailing 写出待写入值
        XCTAssertEqual(written, [1, 3],
                       "首个值立即生效（leading），窗口内中间值被最新值覆盖，flush 写出最后的 3")
    }

    /// 间隔大于窗口时，每次都要写（不能把正常的低频操作也节流掉）。
    func testCallsBeyondIntervalAreNotDropped() {
        var written: [Int] = []
        let throttler = Throttler(interval: 0.02) { written.append($0) }
        for i in 0..<5 {
            throttler.push(i)
            Thread.sleep(forTimeInterval: 0.05)   // 超过窗口
        }
        throttler.flush()
        XCTAssertEqual(written, [0, 1, 2, 3, 4], "间隔超过窗口时每次都应生效（低频操作不受影响）")
    }

    /// flush 后再 push 仍能工作（不能一次 flush 就废了）。
    func testThrottlerRemainsUsableAfterFlush() {
        var written: [Int] = []
        let throttler = Throttler(interval: 0.05) { written.append($0) }
        throttler.push(10)
        throttler.flush()
        throttler.push(20)
        throttler.flush()
        XCTAssertEqual(written, [10, 20])
    }

    /// 性能门禁：1000 次高频 push 的开销必须极小（节流器本身不能成为瓶颈）。
    /// 用户读数是直接调 push，所以 push 必须几乎零成本。
    func testPushIsCheap() {
        var written: [Int] = []
        let throttler = Throttler(interval: 0.05) { written.append($0) }
        let start = Date()
        for i in 0..<1000 { throttler.push(i) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "1000 次 push 必须 < 50ms（实测应远小于），实际 \(String(format: "%.1f", elapsed * 1000))ms")
        throttler.flush()
    }
}
