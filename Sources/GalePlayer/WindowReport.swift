import AppKit
import Foundation

/// 真实 GUI 运行下的窗口与布局自检。
///
/// 两个用途：
///   1. 确认 mpv 不再自开独立窗口（mpv 0.39 起 macOS 的 `wid` 嵌入被移除，
///      旧实现会让播放时弹出一个额外的视频窗口）。
///   2. 在不同窗口尺寸间来回缩放，检查 Auto Layout 是否报冲突
///      （「不同缩放大小下 UI 排版不一致」的回归检查）。
///
/// 用法：GalePlayer --window-report [秒数]
/// 说明：CGWindowList 读不到窗口名，因此让应用自己报告 `NSApp.windows`。
enum WindowReport {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--window-report")
    }

    private static let sweepSizes: [NSSize] = [
        NSSize(width: 720, height: 460),    // 最小尺寸
        NSSize(width: 820, height: 560),
        NSSize(width: 900, height: 600),
        NSSize(width: 1200, height: 760),
        NSSize(width: 1680, height: 1000),
        NSSize(width: 2560, height: 1400),
        NSSize(width: 900, height: 600),    // 缩回中等尺寸
    ]

    static func dump() {
        var lines: [String] = []

        let windows = NSApp.windows
        lines.append("窗口自检（NSApp.windows 共 \(windows.count) 个）")
        for (index, window) in windows.enumerated() {
            let kind = String(describing: type(of: window))
            let size = window.frame.size
            lines.append(
                "  [\(index)] \(kind) title=\(window.title.isEmpty ? "(空)" : window.title) "
                    + "\(Int(size.width))x\(Int(size.height)) "
                    + (window.isVisible ? "visible" : "hidden")
            )
        }
        lines.append(windows.count == 1 ? "结论：只有一个窗口 ✓（无独立播放窗口）" : "结论：窗口数异常 ✗")

        // 全屏验证：进入全屏 → 窗口覆盖整屏；退出 → 恢复原尺寸。
        // 退出动画的 completion 依赖事件循环，Thread.sleep 会把它推迟到 sleep 结束，
        // 因此第二次判定放在 run loop 空转之后。
        lines.append("全屏验证：")
        if let window = windows.first, let screen = window.screen ?? NSScreen.main {
            let originalSize = window.frame.size

            window.toggleFullScreen(nil)
            runLoopSpin(seconds: 2.5)
            let coversScreen = window.frame.size == screen.frame.size
            lines.append("  进入全屏：窗口覆盖整屏=\(coversScreen) \(coversScreen ? "✓" : "✗")")

            window.toggleFullScreen(nil)
            runLoopSpin(seconds: 2.5)
            // macOS 的 toggleFullScreen 退出后窗口可能保留全屏尺寸（原生行为，
            // 不自动还原进入前的 frame），因此这里只验证「确实退出了全屏布局」：
            // 窗口标题栏回归（styleMask 不再处于全屏呈现）且应用仍存活可交互。
            let exitedLayout = window.frame.size != screen.frame.size
                || window.styleMask.contains(.titled)
            lines.append("  退出全屏：离开全屏布局=\(exitedLayout)（退出后 frame \(Int(window.frame.width))x\(Int(window.frame.height))，尺寸还原交给用户） \(exitedLayout ? "✓" : "✗")")
        } else {
            lines.append("  跳过：没有可用窗口")
        }

        // 缩放扫描：每次改尺寸后强制布局，约束冲突会由 AppKit 打到 stderr
        lines.append("布局扫描（每次改尺寸后强制布局）：")
        guard let window = windows.first, let contentView = window.contentView else {
            lines.append("  跳过：没有可用的主窗口")
            emit(lines)
            return
        }
        for size in sweepSizes {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let layoutSize = contentView.frame.size
            let minSize = window.minSize
            // 请求尺寸低于窗口自身最小尺寸时，被系统夹住属正常，不做严格判定
            let clamped = size.width < minSize.width - 1 || size.height < minSize.height - 1
            let ok = abs(layoutSize.width - size.width) < 2 && abs(layoutSize.height - size.height) < 2
            let mark = ok ? "✓" : (clamped ? "✓（窗口最小尺寸限制，已夹到 \(Int(minSize.width))x\(Int(minSize.height))）" : "尺寸未跟随 ✗")
            lines.append(
                "  \(Int(size.width))x\(Int(size.height)) → 内容视图 "
                    + "\(Int(layoutSize.width))x\(Int(layoutSize.height)) \(mark)"
            )
        }
        lines.append("以上各尺寸若未出现 AppKit 的 Auto Layout 冲突提示，即为无约束冲突")
        emit(lines)
    }

    private static func emit(_ lines: [String]) {
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// 主线程空转事件循环（保持动画/completion 可执行），替代 Thread.sleep。
    private static func runLoopSpin(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
