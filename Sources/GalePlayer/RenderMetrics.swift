import AppKit
import Foundation

/// 渲染路径的运行时指标（主线程累加，供资源自检逐秒采样读走）。
///
/// 关注的是**主线程被渲染阻塞的比例**：`flushBuffer` 在 `swapInterval=1` 时
/// 会阻塞到下一次 vsync（最长一个刷新间隔），24fps 播放意味着每秒 24 次、
/// 每次最多 16.7ms —— 这是「播放时按钮发木、菜单卡顿」的根源，
/// 而它在总 CPU 占用上是看不出来的（阻塞 ≠ 消耗 CPU）。
enum RenderMetrics {
    nonisolated(unsafe) static var renderSeconds: Double = 0
    nonisolated(unsafe) static var flushSeconds: Double = 0
    /// 单次 flushBuffer 的最长阻塞（毫秒）
    nonisolated(unsafe) static var maxFlushBlockMS: Double = 0
    nonisolated(unsafe) static var framesPresented: Int = 0
    /// 视频视图收到的单击 / 双击次数（证明鼠标事件真的打到了视图上）
    nonisolated(unsafe) static var singleClicks: Int = 0
    /// 最近一次点击点的命中视图类型（诊断用：能看出被谁挡住）
    nonisolated(unsafe) static var lastHitView: String = "?"
    nonisolated(unsafe) static var doubleClicks: Int = 0
    nonisolated(unsafe) static var swapInterval: Int = 1
    /// 按 mpv 的 target_time 调度了多少次延迟等待（验证新时序确实在跑）
    nonisolated(unsafe) static var targetTimeWaits: Int = 0
    /// 最近一帧 mpv 给的目标显示时刻（微秒，mpv 时钟）
    nonisolated(unsafe) static var lastTargetTimeUs: Int64 = 0

    static func reset() {
        renderSeconds = 0
        flushSeconds = 0
        maxFlushBlockMS = 0
        framesPresented = 0
    }

    /// 只清空与渲染节奏相关的累计值（targetTimeWaits 是累计诊断量，不清）
    static func resetInterval() {
        renderSeconds = 0
        flushSeconds = 0
        maxFlushBlockMS = 0
        framesPresented = 0
    }
}

/// 主线程响应性探针。
///
/// 逻辑：按 16.67ms（60Hz）周期自我派发，记录**实际触发时刻 - 预期时刻**。
/// 正常情况是几毫秒；一旦主线程被 vsync 阻塞或做重活，就会出现几十毫秒的尖峰。
/// 这是最接近「用户点按钮感觉卡不卡」的客观指标。
@MainActor
final class MainThreadLagProbe {
    static let shared = MainThreadLagProbe()

    private var timer: DispatchSourceTimer?
    private var expectedNanos: UInt64
    /// 本采样周期内的最大延迟（秒）
    private(set) var maxLag: Double = 0
    /// 超过该阈值算一次「卡顿」
    private static let jankThreshold: Double = 0.025
    private(set) var jankCount: Int = 0

    private init() { expectedNanos = 0 }

    func start(intervalSeconds: Double = 1.0 / 60.0) {
        guard timer == nil else { return }
        expectedNanos = DispatchTime.now().uptimeNanoseconds
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: intervalSeconds, leeway: .microseconds(200))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            let nowNanos = now.uptimeNanoseconds
            // 定时器可能**略微提前**触发（leeway 允许提前），此时 now < expected，
            // 减法会回绕成天文数字。宁可记 0 也不能让垃圾值混进统计。
            let lag = nowNanos > self.expectedNanos
                ? Double(nowNanos - self.expectedNanos) / 1e9
                : 0
            if lag > self.maxLag { self.maxLag = lag }
            if lag > Self.jankThreshold { self.jankCount += 1 }
            // 用 wrapping 运算：系统运行久了 uptimeNanoseconds 可能非常接近 UInt64 上界，
            // 普通 `+` 会直接触发 arithmetic overflow 崩溃（实测踩过一次）。
            let next = nowNanos &+ UInt64(intervalSeconds * 1e9)
            // 回绕后落到过去会导致后面每次都算成巨大的延迟，这里夹一次。
            self.expectedNanos = next > nowNanos ? next : nowNanos
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 取出并清零本周期统计
    func takeSample() -> (maxLag: Double, jank: Int) {
        let result = (maxLag, jankCount)
        maxLag = 0
        jankCount = 0
        return result
    }
}