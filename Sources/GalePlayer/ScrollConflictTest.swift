import AppKit
import Foundation
import GaleCore

/// 滚轮冲突自检：播放列表上滚轮 ≠ 音量，视频区上滚轮 = 音量。
///
/// 背景：滚轮全局接管（整个窗口都能调音量）后，悬停在播放列表（SwiftUI List）
/// 上滚动时音量也跟着变 —— 列表滚动和音量调节打架。修法是命中测试：
/// 光标下方是 `NSScrollView`（列表底层）就放行给列表滚动，不抢音量。
///
/// 自检直接测判定函数 `GlobalInputController.isScrollableRegion`：
///   1. 播放列表上的点 → 判定「可滚动」= true（滚轮放行给列表，不调音量）
///   2. 视频区上的点 → 判定「可滚动」= false（滚轮才调音量）
///
/// 为什么测判定函数而不是合成滚轮事件走完整派发链：
/// 滚轮→音量的监听是 `NSEvent.addLocalMonitorForEvents`，只有系统投递的
/// 滚轮事件才能带正确 window；而滚轮事件无法无头合成 —— `otherEvent`
/// 不接受 scrollWheel 类型（直接抛异常）、`CGEvent` 造出来的没有 window 关联
/// （实测 window=false）。这是系统限制，不是代码问题；判定函数正是那条
/// 决定「抢不抢音量」的分支，测它等于测修复点本身。
///
/// 用法：GalePlayer --scroll-conflict-test <媒体文件>
enum ScrollConflictTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--scroll-conflict-test")
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
        var lines: [String] = ["滚轮冲突自检（列表滚轮 ≠ 音量）"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--scroll-conflict-test"), args.count > index + 1 else {
            report("用法: --scroll-conflict-test <媒体文件>")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: args[index + 1])
        onMain { core.open(urls: [mediaURL]) }

        // 等窗口与媒体
        var window: NSWindow?
        let deadline = Date().addingTimeInterval(25)
        while window == nil, Date() < deadline {
            window = onMain { NSApp.windows.first { $0.isVisible && !$0.title.isEmpty } }
            if window == nil { Thread.sleep(forTimeInterval: 0.3) }
        }
        guard let window else {
            report((lines + ["  失败：没有可用窗口"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        while onMain({ core.duration }) <= 0, Date() < Date().addingTimeInterval(25) {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 固定窗口尺寸再算坐标（顺序不能反，见 MouseTest 的教训）
        onMain { window.setFrame(NSRect(x: 120, y: 120, width: 1280, height: 860), display: true) }
        Thread.sleep(forTimeInterval: 1.0)
        let frame = onMain { window.frame }

        // 侧栏在右（HSplitView：视频列 + 侧栏），宽度 ~320
        // 播放列表点取右侧栏中部（要在 List 的行上，避开上方工具条）；
        // 视频点取视频列中部。
        let playlistPoint = NSPoint(x: frame.width - 100, y: frame.height * 0.45)
        let videoPoint = NSPoint(x: frame.width * 0.30, y: frame.height * 0.45)

        // 命中链（含滚动标记）供诊断
        lines.append("  播放列表点命中链：")
        lines.append("    " + hitChain(at: playlistPoint, in: window).joined(separator: " → "))
        lines.append("  视频点命中链：")
        lines.append("    " + hitChain(at: videoPoint, in: window).joined(separator: " → "))

        // ---- 判定：列表点应「可滚动」=true（放行给列表，不调音量）----
        let listScrollable = onMain {
            GlobalInputController.shared.isScrollableRegion(atWindowPoint: playlistPoint, in: window)
        }
        let videoScrollable = onMain {
            GlobalInputController.shared.isScrollableRegion(atWindowPoint: videoPoint, in: window)
        }

        lines.append("")
        lines.append("  —— 播放列表上的点 ——")
        lines.append("    判定「可滚动区域」= \(listScrollable)  \(listScrollable ? "✓ 滚轮放行给列表（不调音量）" : "✗ 会被音量抢走（冲突未修）")")
        lines.append("  —— 视频区上的点 ——")
        lines.append("    判定「可滚动区域」= \(videoScrollable)  \(!videoScrollable ? "✓ 滚轮调音量" : "✗ 视频区滚轮也被误判为滚动")")

        let ok = listScrollable && !videoScrollable
        lines.append("")
        lines.append("  结论：" + (ok
            ? "列表点放行给滚动、视频点调音量 ✓"
            : "存在缺陷 ✗（listScrollable=\(listScrollable) videoScrollable=\(videoScrollable)）"))
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 某窗口坐标点的完整命中链（类名 + 滚动标记）。
    private static func hitChain(at point: NSPoint, in window: NSWindow) -> [String] {
        onMain {
            guard let content = window.contentView else { return ["(无 contentView)"] }
            var result: [String] = []
            var view: NSView? = content.hitTest(content.convert(point, from: nil))
            while let current = view {
                var label = String(describing: type(of: current))
                if current is NSScrollView { label += "(滚动)" }
                result.append(label)
                view = current.superview
            }
            return result.prefix(12).map { $0 }
        }
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}
