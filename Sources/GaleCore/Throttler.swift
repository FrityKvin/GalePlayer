import Foundation

/// 通用节流器：把高频事件合并成「最多每 `interval` 秒执行一次 + 最后一次必达」。
///
/// ## 为什么需要（实测数据 2026-11-20）
/// `mpv_set_property("volume")` 是**同步阻塞**调用：单次 10.4ms（p95 16ms）。
/// SwiftUI 的 `Slider` 拖动时每帧都回调，一次完整拖动（101 步）累计在主线程上
/// 卡了 1263ms —— 表现就是「拖动滑条有延迟、不跟手」。
///
/// ## 语义
/// - `push(value)`：记录最新值。若距上次执行已超过 `interval`，立即执行；
///   否则只更新「待写入值」，不执行（窗口内的中间值被**覆盖**，不排队）。
/// - `flush()`：立刻执行待写入值（松手/拖动结束时调用）。
///   **trailing 语义是关键**：只做 leading-edge 节流会让最后的音量停在中途。
///
/// ## 线程
/// 内部用锁保护，可从任意线程 push；执行在**调用方线程**（由持有者决定
/// 放主线程还是后台线程）。
public final class Throttler<Value>: @unchecked Sendable {
    private let interval: TimeInterval
    private let action: (Value) -> Void
    private let lock = NSLock()

    private var lastRun: TimeInterval = 0
    private var pending: Value?
    private var hasPending = false

    /// 时钟（可注入，便于单测）。
    private let clock: () -> TimeInterval

    public init(
        interval: TimeInterval,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        action: @escaping (Value) -> Void
    ) {
        self.interval = max(0, interval)
        self.clock = clock
        self.action = action
    }

    /// 推入一个值。
    public func push(_ value: Value) {
        var toRun: Value?
        lock.lock()
        let now = clock()
        if now - lastRun >= interval {
            // 窗口已过：立即执行
            lastRun = now
            pending = nil
            hasPending = false
            toRun = value
        } else {
            // 窗口内：只记录最新值（覆盖，不排队）
            pending = value
            hasPending = true
        }
        lock.unlock()
        if let toRun { action(toRun) }
    }

    /// 立刻执行待写入值（松手/结束拖动时调用）。
    public func flush() {
        var toRun: Value?
        lock.lock()
        if hasPending {
            toRun = pending
            pending = nil
            hasPending = false
            lastRun = clock()
        }
        lock.unlock()
        if let toRun { action(toRun) }
    }

    /// 清除待写入值（不执行）。用于「放弃本次操作」。
    public func cancel() {
        lock.lock()
        pending = nil
        hasPending = false
        lock.unlock()
    }
}
