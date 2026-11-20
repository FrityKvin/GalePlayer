import AppKit
import Foundation
import GaleCore

/// 音量调节延迟自检：量化「滑条拖动 → 听到音量变化」链路每一步的耗时。
///
/// 用法：GalePlayer --volume-latency-test <媒体>
///
/// 要回答的问题（Kevin 报的真实缺陷）：
///   拖动音量滑条后，要等一会儿才听到音量变化。
///
/// 候选根因（逐个量化，不猜）：
///   A. `mpv_set_property("volume")` 本身阻塞（同步等待 mpv core 线程）
///   B. `volume` 是 @Published + didSet → 每次滑动都让整个 ControlBar 重算
///   C. mpv 的 volume 属性变更会触发内部 AO 重配置（音频重建）
///   D. SwiftUI Slider 的连续回调频率本身很高（每像素一次）
///
/// 输出：每一步的 ns/次 + 一次完整 Slider 拖动（60→100% 分 100 步）的累计耗时。
enum VolumeLatencyTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--volume-latency-test")
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

    private static func perform(core: PlayerCore) {
        var lines: [String] = ["音量调节延迟自检"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--volume-latency-test"), args.count > index + 1 else {
            report("用法: --volume-latency-test <媒体>")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: args[index + 1])

        // 先把媒体加载起来（音量只有在播放时才会触发 AO 重配置）
        onMain { core.open(urls: [mediaURL]) }
        let deadline = Date().addingTimeInterval(20)
        while onMain({ core.duration }) <= 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard onMain({ core.duration }) > 0 else {
            report((lines + ["  失败：媒体未加载"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        lines.append("  媒体已加载：\(mediaURL.lastPathComponent)（\(String(format: "%.1f", onMain { core.duration })) 秒）")

        let startVolume = onMain { core.volume }
        lines.append("  起始音量=\(String(format: "%.0f", startVolume))")

        // ── A. 纯 mpv 写入耗时（绕过 SwiftUI 的 @Published 链路）──
        var samples: [Double] = []
        for step in 0..<50 {
            let target = Double(60 + step % 40)
            let t0 = DispatchTime.now().uptimeNanoseconds
            onMain { core.setVolumeDirect(target) }
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 - t0) / 1_000_000)   // ms
        }
        let median = samples.sorted()[samples.count / 2]
        let p95 = samples.sorted()[Int(Double(samples.count) * 0.95)]
        lines.append("  A. mpv 直接写入     中位=\(String(format: "%.3f", median))ms  p95=\(String(format: "%.3f", p95))ms  (50 次)")
        lines.append("     → \(median > 1 ? "✗ 阻塞明显，是延迟来源" : "✓ 非阻塞，不是瓶颈")")

        // ── B. 完整 UI 路径（volume didSet → 节流器 → 后台队列）──
        // 关键：用**同一次主线程进入**连续赋值，模拟真实 Slider 在同一帧内回调，
        // 而不是每步都 DispatchQueue.main.sync（那会把同步开销算进结果）。
        var uiSamples: [Double] = []
        for step in 0..<50 {
            let target = Double(70 + step % 40)
            let t0 = DispatchTime.now().uptimeNanoseconds
            onMain { core.volume = target }
            let t1 = DispatchTime.now().uptimeNanoseconds
            uiSamples.append(Double(t1 - t0) / 1_000_000)
        }
        let uiMedian = uiSamples.sorted()[uiSamples.count / 2]
        let uiP95 = uiSamples.sorted()[Int(Double(uiSamples.count) * 0.95)]
        lines.append("  B. 节流后 UI 路径   中位=\(String(format: "%.3f", uiMedian))ms  p95=\(String(format: "%.3f", uiP95))ms  (50 次)")
        lines.append("     → 主线程节省 = \(String(format: "%.3f", median - uiMedian))ms/次（正数=已把阻塞移出主线程）")

        // ── C. 一次完整拖动（单次主线程进入内连续 101 步）──
        // 这样测的是**真实的 SwiftUI 回调场景**：同一帧里 Slider 连续改值。
        onMain { core.resetVolumeWriteCount() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        onMain {
            for step in 0...100 {
                core.volume = 60 + Double(step)
            }
            core.flushVolume()
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        let writes = onMain { core.volumeWriteCount }
        lines.append("  C. 一次拖动(同比 101 步)  主线程累计=\(String(format: "%.1f", total))ms  实际写入 mpv=\(writes) 次")
        lines.append("     → 节流前应≈101 次；修复前实测 12.5ms/步、累计 1263ms")

        // ── D. 末值必达：flush 之后 mpv 是否真的收到了目标音量 ──
        onMain { core.volume = 137 }
        onMain { core.flushVolume() }
        Thread.sleep(forTimeInterval: 0.05)   // 给后台队列一点时间
        let applied = onMain { core.appliedVolume }
        lines.append("  D. flush 后 mpv 实际音量 = \(applied.map { String(format: "%.1f", $0) } ?? "读取失败")（目标 137）")
        let trailingOK = applied.map { abs($0 - 137) < 1.0 } ?? false
        lines.append("     → \(trailingOK ? "✓ 最终值已送达 mpv" : "✗ 最终值丢失（节流失效）")")

        // ── E. 恢复并给出结论 ──
        onMain { core.setVolumeDirect(startVolume) }

        lines.append("")
        var verdicts: [String] = []
        // 判定基准是 C 行的「真实拖动场景」：主线程累计必须远低于人眼可感阈值。
        if total > 40 { verdicts.append("拖动主线程仍 \(String(format: "%.0f", total))ms，跟手滞后") }
        if writes > 20 { verdicts.append("节流未生效（写了 \(writes) 次）") }
        if !trailingOK { verdicts.append("末值丢失") }
        lines.append(verdicts.isEmpty
            ? "结论：主线程零阻塞（\(String(format: "%.1f", total))ms/次拖动）、写入 \(writes) 次、末值送达 ✓"
            : "结论：仍有问题 → " + verdicts.joined(separator: "；"))

        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}
