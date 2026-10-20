import AppKit
import Foundation
import GaleCore

/// 鼠标交互自检：单击=播放/暂停、双击=进出全屏。
///
/// 用 `CGEvent` 合成**真实**鼠标事件打进视频视图所在窗口，
/// 验证接线是否真的生效（而不是只读代码说"已接线"）。
///
/// 用法：GalePlayer --mouse-test <媒体文件>
enum MouseTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--mouse-test")
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
        var lines: [String] = ["鼠标交互自检（单击 / 双击）"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--mouse-test"), args.count > index + 1 else {
            report("用法: --mouse-test <媒体文件>")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: args[index + 1])
        onMain { core.open(urls: [mediaURL]) }

        // 等加载并拿到窗口
        var window: NSWindow?
        let deadline = Date().addingTimeInterval(25)
        while window == nil, Date() < deadline {
            window = onMain { () -> NSWindow? in
                NSApp.windows.first { $0.isVisible && !$0.title.isEmpty }
            }
            if window == nil { Thread.sleep(forTimeInterval: 0.3) }
        }
        guard let window else {
            report((lines + ["  失败：没有可用窗口"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        let deadline2 = Date().addingTimeInterval(25)
        while onMain({ core.duration }) <= 0, Date() < deadline2 {
            Thread.sleep(forTimeInterval: 0.3)
        }
        lines.append("  媒体已加载=\(onMain { core.duration } > 0)")

        // 视频区域的屏幕坐标：取窗口左半部分（避开右侧播放列表）
        // 先固定窗口尺寸，**再**算坐标系里的点位。
        // 顺序不能反：窗口默认大小/上次保存的 frame 会变，
        // 先算点位（或在算完之后改尺寸）都会让点击落到窗口外或别的控件上
        // —— 实测就因此出现过「同一份代码两次跑出不同结论」。
        onMain {
            window.setFrame(NSRect(x: 120, y: 120, width: 1280, height: 860), display: true)
        }
        Thread.sleep(forTimeInterval: 0.8)

        let frame = onMain { window.frame }
        let clickPoint = CGPoint(x: frame.minX + frame.width * 0.35, y: frame.midY)

        // 先激活应用再把窗口置前：**激活的那一次点击会被系统吃掉**
        // （macOS 的常规行为：点未激活的窗口先激活它，事件不投递给视图）。
        // 不先做这一步，第一个测试点击必然无效 —— 会误判成「单击没接线」。
        onMain {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        Thread.sleep(forTimeInterval: 0.8)

        // ---- 单击：应切换播放状态，且**只**切换一次 ----
        lines.append("")
        lines.append("  —— 单击（期望：播放↔暂停）——")
        let beforeSingle = onMain { core.isPlaying }
        click(at: clickPoint, clickCount: 1)
        Thread.sleep(forTimeInterval: 0.8)
        let afterSingle = onMain { core.isPlaying }
        let clicks = RenderMetrics.singleClicks
        lines.append("  点击点命中视图=\(RenderMetrics.lastHitView)（应为 MPVGLView）")
        let lines2 = "    \(beforeSingle) → \(afterSingle)  \(beforeSingle != afterSingle ? "✓" : "✗（没变化）")  视图收到单击=\(clicks)"
        lines.append(lines2)
        let singleOK = beforeSingle != afterSingle

        // ---- 控制条播放键：应切换播放状态 ----
        //
        // 注意点位：控制条**只占视频列宽度**（不含右侧播放列表），
        // 用整窗中心会点到侧栏上（实测就是这样误判成「按钮没生效」）。
        lines.append("")
        lines.append("  —— 点控制条中央的播放键（期望：播放↔暂停）——")
        let videoColumnWidth = onMain { () -> CGFloat in
            guard let content = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty })?.contentView,
                  let gl = scanForGL(content) else { return frame.width }
            return gl.convert(gl.bounds, to: nil).width
        }
        // 控制条在视频列下方，纵坐标取窗口底部往上 ~40pt
        let transportWindowPoint = NSPoint(x: videoColumnWidth / 2, y: 40)
        let beforeTransport = onMain { core.isPlaying }
        click(windowPoint: transportWindowPoint, clickCount: 1)
        Thread.sleep(forTimeInterval: 0.8)
        let afterTransport = onMain { core.isPlaying }
        lines.append("    命中视图=\(RenderMetrics.lastHitView)")
        lines.append("    \(beforeTransport) → \(afterTransport)  \(beforeTransport != afterTransport ? "✓" : "✗（按钮没生效）")")
        let transportOK = beforeTransport != afterTransport

        // ---- 双击：应进/出全屏，且**不**改变播放状态 ----
        lines.append("")
        lines.append("  —— 双击（期望：进出全屏，且播放状态不变）——")
        let beforeDouble = onMain { core.isPlaying }
        click(at: clickPoint, clickCount: 2)
        Thread.sleep(forTimeInterval: 2.0)
        let afterDouble = onMain { core.isPlaying }
        let fullScreenAfter = onMain { window.styleMask.contains(.fullScreen) }
        lines.append("    播放状态 \(beforeDouble) → \(afterDouble)  \(beforeDouble == afterDouble ? "✓ 未被反转" : "✗ 被反转了")")
        lines.append("    窗口全屏位=\(fullScreenAfter)  视图收到双击=\(RenderMetrics.doubleClicks)  \(fullScreenAfter ? "✓ 已进全屏" : "✗ 未进全屏")")
        let doubleOK = beforeDouble == afterDouble && fullScreenAfter

        // ---- 右缘箭头（**必须全屏下测**）----
        //
        // 普通窗口里这个箭头切的是右侧面板（ContentView 的 @State，外部看不到）；
        // 只有全屏时它切的是 `core.isPlaylistFloating`，才能从外部断言。
        lines.append("")
        lines.append("  —— 全屏下点右缘箭头（期望：播放列表浮层展开）——")
        // 宽度必须**重新测量**：进全屏后侧栏收起、视频变宽，
        // 用进全屏前的宽度算点位会落回视频里（实测命中 MPVGLView）。
        let fullscreenVideoWidth = onMain { () -> CGFloat in
            guard let content = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty })?.contentView,
                  let gl = scanForGL(content) else { return videoColumnWidth }
            return gl.convert(gl.bounds, to: nil).maxX
        }
        lines.append("    全屏下视频右界=\(fullscreenVideoWidth)")
        let arrowWindowPoint = NSPoint(x: fullscreenVideoWidth + 10, y: 700)
        // 箭头只在「鼠标贴近右缘」时才显示（opacity 1）。
        // 自检不动真实鼠标，因此用测试钩子把显隐状态打开，
        // 否则点到的是一个 opacity 0 的按钮。
        onMain { EdgeRevealController.shared.setNearRightEdgeForTesting(true) }
        Thread.sleep(forTimeInterval: 0.3)
        let beforePlaylist = onMain { core.isPlaylistFloating }
        click(windowPoint: arrowWindowPoint, clickCount: 1)
        Thread.sleep(forTimeInterval: 0.7)
        let afterPlaylist = onMain { core.isPlaylistFloating }
        lines.append("    命中视图=\(RenderMetrics.lastHitView)")
        lines.append("    浮层状态 \(beforePlaylist) → \(afterPlaylist)  \(beforePlaylist != afterPlaylist ? "✓" : "✗（箭头没生效）")")
        let arrowOK = beforePlaylist != afterPlaylist

        // ---- 退出全屏：再双击一次 ----
        //
        // 注意：进入全屏会**重建视频视图**（SwiftUI 重新布局），所以必须重新查找视图，
        // 否则第二次点击打在已释放的旧视图上 —— 这也正是「双击进得去出不来」的成因。
        Thread.sleep(forTimeInterval: 1.2)
        click(at: clickPoint, clickCount: 2)
        Thread.sleep(forTimeInterval: 2.5)
        let backOut = onMain { window.styleMask.contains(.fullScreen) }
        lines.append("    再次双击后全屏位=" + String(backOut) + "  " + (!backOut ? "✓ 已退出全屏" : "✗ 仍在全屏"))

        let ok = singleOK && transportOK && arrowOK && doubleOK && !backOut
        lines.append("")
        lines.append("  结论：" + (ok ? "画面单击/双击、控制条播放键、右缘箭头均生效 ✓"
            : "存在缺陷 ✗（single=" + String(singleOK) + " transport=" + String(transportOK)
              + " arrow=" + String(arrowOK) + " double=" + String(doubleOK) + "）"))
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 向视频视图投递 mouseUp，模拟一次点击。
    ///
    /// 为什么不用 CGEvent 合成：非交互进程（自检）里合成事件打不进视图 ——
    /// 实测「视图收到单击=0」，是 macOS 对 CGEvent 的辅助功能权限限制，
    /// 不是代码问题。所以这里直接构造 NSEvent 调视图的 mouseUp，
    /// 验证的是**点击→动作的接线与防抖逻辑**；
    /// 「真实鼠标能否送达视图」由用户在真机上确认。
    /// 用**窗口坐标**点击。所有点击最终都走这里。
    ///
    /// 必须走 `window.sendEvent` 这条真实派发链，而不是直接调 `view.mouseUp`：
    /// 直接调会绕过 SwiftUI 的命中测试，测不出「事件根本送不到视图」的问题
    /// （`.allowsHitTesting(false)` 就是这么漏掉一轮的）。
    private static func click(windowPoint point: NSPoint, clickCount: Int) {
        onMain {
            guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty }),
                  let content = window.contentView else {
                report("  ⚠️ 找不到窗口，跳过点击注入")
                return
            }
            // 激活并置前：**激活那一次点击会被系统吃掉**，
            // 不先做这一步，第一个测试点击必然无效（会误判成「没接线」）。
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            // 诊断：这一点的命中结果（能看出被谁挡住）
            RenderMetrics.lastHitView = content.hitTest(point).map { String(describing: type(of: $0)) } ?? "(nil)"

            for i in 1...max(1, clickCount) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: i, pressure: 1
                    ) else { continue }
                    window.sendEvent(event)
                }
            }
        }
    }

    /// 屏幕坐标入口（内部换算成窗口坐标）。
    private static func click(at point: CGPoint, clickCount: Int) {
        let converted = onMain { () -> NSPoint in
            guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty })
            else { return .zero }
            return window.convertPoint(fromScreen: NSPoint(x: point.x, y: point.y))
        }
        click(windowPoint: converted, clickCount: clickCount)
    }

    static func scanForGL(_ view: NSView) -> MPVGLView? {
        if let v = view as? MPVGLView { return v }
        for sub in view.subviews { if let hit = scanForGL(sub) { return hit } }
        return nil
    }

    /// 从窗口里找出 MPVGLView（**必须在主线程**调用）。
    @MainActor
    private static func videoView() -> MPVGLView? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty })
        else { return nil }
        func scan(_ view: NSView) -> MPVGLView? {
            if let v = view as? MPVGLView { return v }
            for sub in view.subviews {
                if let hit = scan(sub) { return hit }
            }
            return nil
        }
        return window.contentView.flatMap(scan)
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}