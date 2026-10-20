import AppKit
import Darwin
import Foundation

/// 渲染/重算计数器 —— 用来量化「有多少状态变化把整棵视图树重算了一遍」。
///
/// SwiftUI 里最常见的资源浪费不是绘制，而是**过宽的依赖**：
/// 一个 `@EnvironmentObject` 的任何 `@Published` 变化都会让用到它的整个子树重算，
/// 所以「每秒重算多少次 body」比帧率更能说明浪费。
enum RenderCounters {
    nonisolated(unsafe) static var contentView = 0
    nonisolated(unsafe) static var controlBar = 0
    nonisolated(unsafe) static var seekBar = 0
    nonisolated(unsafe) static var playlistPanel = 0
    /// 自动「下一个」测试钩子的触发次数（用 GALE_ADVANCE_AFTER 开启）
    nonisolated(unsafe) static var autoAdvanceTick = 0

    static func reset() {
        contentView = 0
        controlBar = 0
        seekBar = 0
        playlistPanel = 0
    }
}

/// 一次采样的资源数据。
struct ResourceSample {
    /// 本进程累计占用的 CPU 时间（秒，含所有线程）
    let cpuSeconds: Double
    /// 物理内存占用（字节，含 framework 与映射）
    let footprintBytes: Int
    /// 线程数
    let threads: Int

    /// 本进程累计 CPU 时间（用户 + 系统，纳秒）
    private static func cpuNanos() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) * 1e9 + Double(usage.ru_utime.tv_usec) * 1_000
        let system = Double(usage.ru_stime.tv_sec) * 1e9 + Double(usage.ru_stime.tv_usec) * 1_000
        return user + system
    }

    /// 物理内存占用（phys_footprint，与「活动监视器」口径一致）
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private static func threadCount() -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Int(info.pti_threadnum)
    }

    static func take() -> ResourceSample {
        ResourceSample(
            cpuSeconds: cpuNanos() / 1e9,
            footprintBytes: footprint(),
            threads: threadCount()
        )
    }
}

/// 资源占用自检：分别测「空闲」与「播放中」的 CPU / 内存 / 线程 / 视图重算。
///
/// 用法：GalePlayer --resource-test <媒体文件>
enum ResourceReport {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--resource-test")
    }

    @MainActor
    static func start(core: PlayerCore?) {
        guard let core else {
            report("  失败：PlayerCore 未就绪")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            perform(core: core)
        }
    }

    private struct Phase {
        let name: String
        /// 该阶段内实际推进的播放秒数（用来确认这一阶段真的在播）
        let advancedSeconds: Double
        let playingFlag: Bool
        let cpuPercentOfOneCore: Double
        let footprintMB: Double
        let threads: Int
        let contentViewPerSec: Double
        let controlBarPerSec: Double
        let seekBarPerSec: Double
        let playlistPerSec: Double
    }

    private static func perform(core: PlayerCore) {
        var lines: [String] = ["资源占用自检"]

        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--resource-test"), arguments.count > index + 1 else {
            report("用法: --resource-test <媒体文件>")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: arguments[index + 1])

        // 预热：让 SwiftUI 完成首轮布局，避免把启动开销算进稳定期
        onMain { core.open(urls: [mediaURL]) }
        let deadline = Date().addingTimeInterval(20)
        while onMain({ core.duration }) <= 0, Date() < deadline {
            sleep(0.4)
        }
        guard onMain({ core.duration }) > 0 else {
            report((lines + ["  失败：媒体未加载"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }

        var phases: [Phase] = []

        // 阶段 1：暂停（= 空闲：没有新帧、不解码）
        onMain { core.setPaused(true) }
        sleep(1.5)
        phases.append(measure(name: "暂停/空闲", seconds: 6, core: core))

        // 阶段 2：播放中
        onMain { core.setPaused(false) }
        sleep(1.5)
        phases.append(measure(name: "播放中", seconds: 8, core: core))

        // 阶段 3：播放中 + 全屏布局（另一条 UI 路径）
        onMain { core.setFullScreen(true) }
        sleep(1.5)
        phases.append(measure(name: "播放中(全屏布局)", seconds: 6, core: core))
        onMain { core.setFullScreen(false) }

        // 输出
        lines.append("  阶段                CPU(单核)  内存      线程  ContentView/s  ControlBar/s  进度条/s  列表/s   阶段内推进")
        for phase in phases {
            lines.append(
                String(
                    format: "  %-18@ %6.1f%%  %6.1f MB  %4d  %10.1f  %11.1f  %8.1f  %6.1f   %+.1fs %@",
                    phase.name as NSString,
                    phase.cpuPercentOfOneCore,
                    phase.footprintMB,
                    phase.threads,
                    phase.contentViewPerSec,
                    phase.controlBarPerSec,
                    phase.seekBarPerSec,
                    phase.playlistPerSec,
                    phase.advancedSeconds,
                    phase.playingFlag ? "播放中" : "已暂停"
                )
            )
        }

        // 结论提示
        let idle = phases[0]
        let playing = phases[1]
        lines.append("")
        lines.append(String(format: "  空闲 CPU=%.1f%% 单核（空闲时的固定开销主要来自轮询器）", idle.cpuPercentOfOneCore))
        lines.append(String(format: "  播放 CPU=%.1f%% 单核（解码+渲染，随编码/硬解情况变化）", playing.cpuPercentOfOneCore))
        lines.append(String(format: "  空闲 ContentView 重算=%.1f 次/秒 —— 理想值接近 0", idle.contentViewPerSec))
        lines.append(String(format: "  播放 ContentView 重算=%.1f 次/秒（每次都会重算整棵视图树）", playing.contentViewPerSec))
        lines.append(String(format: "  播放 进度条重算=%.1f 次/秒", playing.seekBarPerSec))

        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 采样一个阶段：返回该阶段的 CPU/内存/线程/重算频率。
    private static func measure(name: String, seconds: Double, core: PlayerCore) -> Phase {
        onMain { RenderCounters.reset() }
        let start = ResourceSample.take()
        let startPos = onMain { core.timePos }
        let playing = onMain { core.isPlaying }
        let startedAt = DispatchTime.now()
        sleep(seconds)
        let end = ResourceSample.take()
        let advanced = onMain { core.timePos } - startPos
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1e9

        let cpuPercent = elapsed > 0 ? (end.cpuSeconds - start.cpuSeconds) / elapsed * 100 : 0
        return Phase(
            name: name,
            advancedSeconds: advanced,
            playingFlag: playing,
            cpuPercentOfOneCore: cpuPercent,
            footprintMB: Double(end.footprintBytes) / 1_048_576,
            threads: end.threads,
            contentViewPerSec: Double(RenderCounters.contentView) / elapsed,
            controlBarPerSec: Double(RenderCounters.controlBar) / elapsed,
            seekBarPerSec: Double(RenderCounters.seekBar) / elapsed,
            playlistPerSec: Double(RenderCounters.playlistPanel) / elapsed
        )
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func sleep(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}
/// 真实 GUI 实例的资源采样落盘（供外部测量真实播放态）。
///
/// 为什么需要它：自检进程不是交互应用，mpv 在里面**不推进播放**
/// （实测「播放中」阶段 timePos 推进 +0.0s），此时测出的 CPU/重算没有意义。
/// 真正可信的数字必须来自 `open -a` 启动的正常实例，所以让它自己每秒写一行 JSON：
///
/// ```bash
/// launchctl setenv GALE_RESOURCE_DUMP /tmp/gale-resource.jsonl
/// open -a Gale 视频.mp4 ; sleep 20
/// launchctl unsetenv GALE_RESOURCE_DUMP
/// ```
enum ResourceDump {
    /// 采样时读取播放状态用（避免为了状态去改调用方签名）
    @MainActor static weak var coreRef: PlayerCore?

    @MainActor
    static func startIfRequested(core: PlayerCore? = nil) {
        coreRef = core
        guard let path = ProcessInfo.processInfo.environment["GALE_RESOURCE_DUMP"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        // 覆盖旧文件，避免和上一次测量混在一起
        try? Data().write(to: url)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                let sample = ResourceSample.take()
                MainThreadLagProbe.shared.start()
                let lagSample = MainThreadLagProbe.shared.takeSample()
                let lag = lagSample.maxLag
                let jank = lagSample.jank
                let core = ResourceDump.coreRef
                let payload: [String: Any] = [
                    "pos": core.map { String(format: "%.2f", $0.timePos) } ?? "?",
                    "playing": core?.isPlaying ?? false,
                    "hwdec": core?.hwdecCurrent ?? "?",
                    "renderPct": String(format: "%.1f", RenderMetrics.renderSeconds),
                    "flushPct": String(format: "%.1f", RenderMetrics.flushSeconds),
                    "flushMaxMS": String(format: "%.1f", RenderMetrics.maxFlushBlockMS),
                    "frames": RenderMetrics.framesPresented,
                    "swapInterval": RenderMetrics.swapInterval,
                    "targetWaits": RenderMetrics.targetTimeWaits,
                    "advanceTick": RenderCounters.autoAdvanceTick,
                    "currentHits": core?.highlightMatchCount ?? -1,
                    "playingFile": (core?.currentURL?.lastPathComponent ?? "-"),
                    "isPlaying": core?.isPlaying ?? false,
                    "singleClicks": RenderMetrics.singleClicks,
                    "doubleClicks": RenderMetrics.doubleClicks,
                    "fullscreen": core?.isFullScreen ?? false,
                    "lastTargetUs": RenderMetrics.lastTargetTimeUs,
                    "lagMaxMS": String(format: "%.1f", lag * 1000),
                    "jank": String(jank),
                    "cpu": String(format: "%.3f", sample.cpuSeconds),
                    "footprintMB": String(format: "%.1f", Double(sample.footprintBytes) / 1_048_576),
                    "threads": sample.threads,
                    "contentView": RenderCounters.contentView,
                    "controlBar": RenderCounters.controlBar,
                    "seekBar": RenderCounters.seekBar,
                    "playlist": RenderCounters.playlistPanel,
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      var line = String(data: data, encoding: .utf8) else { return }
                line.append("\n")
                RenderMetrics.resetInterval()
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                } else {
                    try? Data(line.utf8).write(to: url, options: .atomic)
                }
            }
        }
        timer.resume()
        // 故意常驻到进程结束
        objc_setAssociatedObject(timer, &AssociatedKeys.dumper, timer, .OBJC_ASSOCIATION_RETAIN)
    }

    /// 自动切到下一个：验证「高亮是否随播放项移动」时用它替代手工点击。
    /// `GALE_ADVANCE_AFTER=6` → 播 6 秒后调一次 `playNext()`（每 6 秒一次）。
    @MainActor
    static func scheduleAutoAdvanceIfRequested(core: PlayerCore) {
        guard let raw = ProcessInfo.processInfo.environment["GALE_ADVANCE_AFTER"],
              let seconds = Double(raw), seconds > 0 else { return }
        func step(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    guard core.currentURL != nil else { return }
                    core.playNext()
                    // 把当前播放项写进采样，便于和截图对照
                    RenderCounters.autoAdvanceTick = n
                    step(n + 1)
                }
            }
        }
        step(1)
    }

    /// 供测量「暂停态」：`GALE_PAUSE_AFTER=10` → 播放 10 秒后自动暂停。
    /// 用环境变量而不是 AppleScript，是因为脚本控制键盘事件在无人值守时不可靠。
    @MainActor
    static func scheduleAutoPauseIfRequested(core: PlayerCore) {
        guard let raw = ProcessInfo.processInfo.environment["GALE_PAUSE_AFTER"],
              let seconds = Double(raw), seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                core.setPaused(true)
            }
        }
    }

    private enum AssociatedKeys {
        nonisolated(unsafe) static var dumper: UInt8 = 0
    }
}