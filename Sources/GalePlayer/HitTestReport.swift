import AppKit
import Foundation
import GaleCore

/// 命中测试诊断：在窗口若干关键位置上打印**完整命中链**。
///
/// 用途：定位「按钮/画面点不动」这类问题 —— 是事件被上层视图挡住了，
/// 还是 SwiftUI 的 `allowsHitTesting(false)` 把它禁掉了，
/// 还是事件根本没派发到目标视图。
///
/// 用法：GalePlayer --hit-test-report <媒体文件>
enum HitTestReport {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--hit-test-report")
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
        _ = core
    }

    private static func perform(core: PlayerCore) {
        var lines: [String] = ["命中测试诊断"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--hit-test-report"), args.count > index + 1 else {
            report("用法: --hit-test-report <媒体文件>")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: args[index + 1])
        onMain { core.open(urls: [mediaURL]) }

        var window: NSWindow?
        let deadline = Date().addingTimeInterval(25)
        while window == nil, Date() < deadline {
            window = onMain { NSApp.windows.first { $0.isVisible && !$0.title.isEmpty } }
            if window == nil { Thread.sleep(forTimeInterval: 0.3) }
        }
        guard let window, let content = window.contentView else {
            report((lines + ["  失败：没有可用窗口"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        while onMain({ core.duration }) <= 0, Date() < Date().addingTimeInterval(25) {
            Thread.sleep(forTimeInterval: 0.3)
        }

        let frame = onMain { window.frame }
        lines.append("  窗口 frame=\(frame)")
        lines.append("  allowsHitTesting 检查：窗口内各点命中链")
        lines.append("")

        // 关键点位（屏幕坐标 → 窗口坐标）
        let probes: [(String, CGPoint)] = [
            ("视频中心", CGPoint(x: frame.minX + frame.width * 0.30, y: frame.midY)),
            ("视频右缘内 8pt", CGPoint(x: frame.minX + frame.width * 0.68, y: frame.midY)),
            ("控制条中央(播放键)", CGPoint(x: frame.midX, y: frame.minY + 34)),
            ("播放列表面板内", CGPoint(x: frame.maxX - 100, y: frame.midY)),
        ]

        for (name, screenPoint) in probes {
            let inWindow = onMain { window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y)) }
            let chain = onMain { () -> [String] in
                var result: [String] = []
                var view: NSView? = content.hitTest(inWindow)
                while let current = view {
                    var label = String(describing: type(of: current))
                    if current is NSScrollView { label += "  ←NSScrollView" }
                    if current is NSClipView { label += "  ←NSClipView" }
                    if current is NSTableView { label += "  ←NSTableView" }
                    result.append(label)
                    view = current.superview
                }
                return result
            }
            let head = chain.first ?? "(nil —— 该点没有任何视图命中)"
            lines.append("  \(name)：\(head)")
            if chain.count > 1 {
                lines.append("      链：\(chain.prefix(20).joined(separator: " → "))")
            }
            lines.append("")
        }

        // 视频视图的可用性：能否找到、是否隐藏、frame 是否合理
        let info = onMain { () -> String in
            func scan(_ view: NSView) -> MPVGLView? {
                if let v = view as? MPVGLView { return v }
                for sub in view.subviews { if let hit = scan(sub) { return hit } }
                return nil
            }
            guard let glView = scan(content) else { return "找不到 MPVGLView" }
            let inWindowFrame = glView.convert(glView.bounds, to: nil)
            return """
            找到 MPVGLView：hidden=\(glView.isHidden) alpha=\(glView.alphaValue) \
            frame(窗口坐标)=\(inWindowFrame) 可命中=\(glView.hitTest(glView.convert(glView.bounds.origin, to: nil)) != nil)
            """
        }
        lines.append("  \(info)")

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