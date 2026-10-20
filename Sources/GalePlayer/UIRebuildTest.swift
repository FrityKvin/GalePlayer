import AppKit
import Foundation

/// 真实 UI 的视图重建回归测试（端到端）。
///
/// 为什么需要它：`LifecycleTest` 直接操作 `MPVGLView`，验证的是「拆卸/释放」语义；
/// 但真正触发 incident 5693B60E 的是 **SwiftUI 换掉视图** —— `ContentView` 里
/// 普通布局与全屏布局各有一个 `VideoStage()`（`if isFullScreen` 两个分支），
/// 状态一变就会销毁一个视图、新建另一个。本测试因此直接驱动这个状态，
/// 走真实的 `makeNSView` / `dismantleNSView` / `PlayerCore.attach` 路径。
///
/// 检查项：
///   - 进程存活（原始代码会崩在 mpv vo 线程的 objc_retain）
///   - 每次重建后新视图都拿到渲染上下文（原始代码会因旧上下文未释放而创建失败 -20）
///   - 全屏状态回写逻辑（读窗口 styleMask.fullScreen 位）判定正确
///
/// 用法：GalePlayer --ui-rebuild-test <媒体文件>
enum UIRebuildTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--ui-rebuild-test")
    }

    static func mediaPath() -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-rebuild-test"), arguments.count > index + 1 else {
            return nil
        }
        return arguments[index + 1]
    }

    @MainActor
    static func run(core: PlayerCore?) {
        guard let core else {
            report("  失败：PlayerCore 未就绪")
            NSApp.terminate(nil)
            return
        }
        guard let path = mediaPath() else {
            report("  失败：缺少媒体文件参数")
            NSApp.terminate(nil)
            return
        }

        var lines: [String] = ["真实 UI 视图重建自检"]
        lines.append("  媒体：\((path as NSString).lastPathComponent)")

        core.open(urls: [URL(fileURLWithPath: path)])
        spin(seconds: 2.5)
        lines.append("  阶段1 加载完成，视图可渲染=\(core.isVideoViewRenderable)")
        lines.append(contentsOf: ["  阶段1.5 空闲时命中测试：\(hitTestProbe())"])

        NSApp.activate(ignoringOtherApps: true)
        spin(seconds: 0.5)

        // 阶段2：直接驱动 ContentView 的分支切换（普通布局 ⇄ 全屏布局）。
        // 每次切换都会销毁一个 VideoStage、新建另一个 —— 正是崩溃触发点。
        var rebuildFailures = 0
        for round in 1...4 {
            core.setFullScreen(true)
            spin(seconds: 1.2)
            let enterOK = core.isVideoViewRenderable
            core.setFullScreen(false)
            spin(seconds: 1.2)
            let exitOK = core.isVideoViewRenderable
            if !(enterOK && exitOK) { rebuildFailures += 1 }
            lines.append(
                "  阶段2.\(round) 布局切换：全屏布局可渲染=\(enterOK) 普通布局可渲染=\(exitOK)"
                    + ((enterOK && exitOK) ? " ✓" : " ✗（渲染上下文创建撞车 -20）")
            )
        }

        // 阶段3：原生全屏（窗口层），验证全屏状态回写逻辑本身是否正确。
        // 说明：自检进程非交互运行，全屏转场可能不完成（不投递 didEnterFullScreen 通知），
        // 所以这里直接验证「读窗口 styleMask 位」这套判定，而不赌通知投递。
        if let window = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty }) {
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
            spin(seconds: 2.5)
            let windowSaysFullScreen = window.styleMask.contains(.fullScreen)
            let helperSaysFullScreen = FullScreenObserver.currentWindowInFullScreen()
            core.setFullScreen(helperSaysFullScreen)
            lines.append(
                "  阶段3 原生全屏：窗口全屏位=\(windowSaysFullScreen) 判定逻辑读到=\(helperSaysFullScreen)"
                    + " core.isFullScreen=\(core.isFullScreen)"
                    + (windowSaysFullScreen == helperSaysFullScreen ? " ✓（判定一致）" : " ✗（判定不一致）")
            )
            window.toggleFullScreen(nil)
            spin(seconds: 2.0)
        }

        // 阶段4：全屏下的播放列表浮层（右缘箭头点出来的那个面板）
        core.setFullScreen(true)
        spin(seconds: 1.2)
        core.isPlaylistFloating = true
        spin(seconds: 1.2)
        let floatingOK = core.isVideoViewRenderable && core.isPlaylistFloating
        core.isPlaylistFloating = false
        core.setFullScreen(false)
        spin(seconds: 1.2)
        lines.append(
            "  阶段4 全屏播放列表浮层：可渲染=\(core.isVideoViewRenderable) 浮层可开合=\(floatingOK)"
                + (floatingOK ? " ✓" : " ✗")
        )

        // 阶段5：换片再触发一次结构性重建
        core.open(urls: [URL(fileURLWithPath: path)])
        spin(seconds: 2.0)
        lines.append("  阶段5 重新载入后视图可渲染=\(core.isVideoViewRenderable)")

        // 阶段6：播放期间的主线程响应性（判断悬停 UI 是否会被渲染饿死）
        let jitter = measureMainThreadJitter(seconds: 3)
        lines.append(
            "  阶段6 播放中主线程 3 秒抖动：平均 \(jitter.average) ms 最大 \(jitter.max) ms"
                + (jitter.max < 40 ? " ✓（悬停可及时响应）" : " ✗（主线程被占满，悬停会延迟）")
        )
        lines.append("  阶段6.5 播放中命中测试：\(hitTestProbe())")

        // 可见窗口数：排除 AppKit 内部窗口（`_NS...`，含全屏过渡浮层）
        let visible = NSApp.windows.filter { window in
            window.isVisible && !String(describing: type(of: window)).hasPrefix("_NS")
        }
        lines.append("  可见播放窗口数=\(visible.count)（应为 1，播放不得另开窗口）")

        let verdict = rebuildFailures == 0
            ? "  结论：真实 UI 反复重建视图，无崩溃、无 -20 ✓"
            : "  结论：\(rebuildFailures) 轮重建后视图拿不到渲染上下文 ✗"
        lines.append(verdict)
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 主线程空转事件循环（不能用 Thread.sleep：会推迟 AppKit 动画与 SwiftUI 更新）。
    @MainActor
    private static func spin(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// 以 60Hz 定时器测主线程响应抖动（毫秒）。
    ///
    /// 用途：判断「悬停出现的 UI 在播放时不显示」是不是主线程被渲染饿死导致的 ——
    /// 悬停事件本身要先经过主线程，主线程满载时状态更新会明显滞后。
    @MainActor
    private static func measureMainThreadJitter(seconds: TimeInterval) -> (average: Int, max: Int) {
        var samples: [Int] = []
        let interval = 1.0 / 60.0
        var expected = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler {
            let now = DispatchTime.now()
            let lateness = now.uptimeNanoseconds - expected.uptimeNanoseconds
            samples.append(Int(lateness / 1_000_000))
            expected = now
        }
        timer.resume()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        timer.cancel()
        guard !samples.isEmpty else { return (0, 0) }
        return (samples.reduce(0, +) / samples.count, samples.max() ?? 0)
    }

    /// 命中测试探针：问 AppKit「视频区右缘那个点上到底是哪个视图」。
    ///
    /// 用途：`NSOpenGLView` 若在 SwiftUI 浮层之上，它会吃掉鼠标移动事件，
    /// 导致右缘箭头的 `onHover` 永远不触发（症状：播放时箭头不出现）。
    @MainActor
    private static func hitTestProbe() -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.title.isEmpty }),
              let content = window.contentView else { return "无窗口" }
        let bounds = content.bounds
        let y = bounds.midY

        func name(_ x: CGFloat) -> String {
            content.hitTest(NSPoint(x: x, y: y)).map { String(describing: type(of: $0)) } ?? "nil"
        }

        // 从右往左找第一个命中 GL 视图的 x —— 那里已经在视频区内部；
        // 再往右一格就是视频区的右边界。
        var firstGLX: CGFloat?
        var x = bounds.maxX - 1
        while x > 0 {
            if name(x) == "MPVGLView" { firstGLX = x; break }
            x -= 2
        }
        guard let glX = firstGLX else {
            return "窗口 \(Int(bounds.width))x\(Int(bounds.height)) 未找到 GL 视图区域（右缘=\(name(bounds.maxX - 4)))"
        }
        let videoRight = glX + 2
        // 标签列紧贴视频右界向右延伸 20pt；这几处若仍命中 MPVGLView，说明它又被 GL 视图盖住了
        let column = [2, 6, 12, 18].map { offset -> String in
            "列内\(offset)=\(name(videoRight + CGFloat(offset)))"
        }.joined(separator: " ")
        return "窗口 \(Int(bounds.width))x\(Int(bounds.height)) 视频右界≈\(Int(videoRight)) "
            + "｜\(column) 视频内=\(name(videoRight - 6))"
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}
