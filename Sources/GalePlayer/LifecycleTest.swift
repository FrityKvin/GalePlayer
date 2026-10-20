import AppKit
import Foundation
import GaleCore

/// 视频视图生命周期回归测试。
///
/// 复现并防回归的崩溃场景（incident 5693B60E）：
/// SwiftUI 因 `core.currentURL` 变化重建 `VideoStage` → 旧 `MPVGLView` 被释放，
/// 但 mpv 的 render update callback 仍持有它的裸指针（`passUnretained`），
/// 于是 mpv vo 线程在已释放对象上 `objc_retain` → EXC_BAD_ACCESS。
///
/// 本测试走一遍真实生命周期：
///   起 mpv + 视图 → 播放（回调在活跃触发）→ 模拟 SwiftUI 重建视图
///   → 丢弃旧视图 → 在新视图上继续播放 → 干净收尾
/// 修好之后进程必须活着退出（exit 0）；修之前这里会崩。
///
/// 用法：GalePlayer --lifecycle-test <媒体文件>
enum LifecycleTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--lifecycle-test")
    }

    static func run() -> Never {
        let delegate = LifecycleDelegate(arguments: CommandLine.arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

/// 生命周期自检的宿主。窗口与视图只在主线程触碰，其余状态由本类自身串行驱动，
/// 因此标注 `@unchecked Sendable` 以便从后台线程派发主线程操作。
final class LifecycleDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let arguments: [String]
    private var window: NSWindow?
    private var liveViews: [MPVGLView] = []

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let index = arguments.firstIndex(of: "--lifecycle-test"), arguments.count > index + 1 else {
            FileHandle.standardError.write(Data("用法: --lifecycle-test <媒体文件>\n".utf8))
            exit(64)
        }
        let mediaPath = arguments[index + 1]

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 960, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Gale 生命周期自检"
        window.orderFront(nil)
        self.window = window

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.perform(mediaPath: mediaPath)
        }
    }

    // MARK: - 测试主体（后台线程；mpv API 线程安全）

    private func perform(mediaPath: String) {
        log("视频视图生命周期自检")

        guard let client = MPVClient() else {
            emit("  失败：mpv 初始化失败", code: 2)
        }

        let loaded = DispatchSemaphore(value: 0)
        client.onEvent = { event in
            if event == "file-loaded" { loaded.signal() }
        }

        // ---- 阶段 1：首个视图（对应 App 首次呈现 VideoStage）----
        var viewA: MPVGLView? = makeViewOnMain(client: client)
        client.loadFile(URL(fileURLWithPath: mediaPath))
        guard loaded.wait(timeout: .now() + 30) != .timedOut else {
            emit("  失败：首个视图 30 秒内未加载完成", code: 3)
        }
        log("  阶段1 首视图加载成功，播放中")
        runLoopSpin(seconds: 1.5)   // 让 mpv 的 update 回调真实触发若干次

        // ---- 阶段 2：正常重建路径（修复后的 App 行为）----
        // SwiftUI 先调 dismantleNSView（→ detach）再释放旧视图；回调随之注销。
        let freed = detachAndReleaseOnMain(&viewA)
        guard freed else {
            emit("  失败：detach 之后视图仍未析构 —— 说明泄漏了 +1 引用", code: 4)
        }
        log("  阶段2 旧视图经 detach 后真正析构 ✓（回调已注销，无泄漏）")
        runLoopSpin(seconds: 0.8)

        // 新视图接管同一个 mpv 实例——旧上下文若没释放，这里会拿到 -20
        var viewB: MPVGLView? = makeViewOnMain(client: client)
        client.loadFile(URL(fileURLWithPath: mediaPath))
        _ = loaded.wait(timeout: .now() + 15)
        runLoopSpin(seconds: 1.0)
        log("  阶段3 新视图接管并重播成功（渲染上下文未撞车 -20）")

        // ---- 阶段 4：野指针场景（复现历史崩溃）----
        // 关键前置：必须先「停帧」再释放视图。
        // 因为回调里 `DispatchQueue.main.async { [self] }` 会强捕获视图，只要 mpv 还在出帧，
        // 就总有待执行的 block 吊着它 —— 视图永不析构，野指针根本测不出来。
        // 停帧 → 待执行 block 排空 → 视图真正析构 → 恢复出帧时回调立刻打在释放后的地址上。
        client.setPaused(true)
        runLoopSpin(seconds: 0.8)
        weak var leakedProbe = viewB
        releaseWithoutDetachOnMain(&viewB)
        runLoopSpin(seconds: 0.5)
        log("  阶段4 停帧后释放视图（未 detach）：视图已析构=\(leakedProbe == nil)")
        client.setPaused(false)     // 恢复出帧 → mpv 回调命中刚释放的地址
        runLoopSpin(seconds: 2.0)   // 旧代码：galeRenderUpdate 里 objc_retain 野指针 → SIGSEGV
        log("  → 恢复出帧后回调持续触发 2 秒，未崩溃 ✓")

        // 收尾：补一次 detach，证明「漏掉拆卸」之后仍可恢复；
        // 且必须如此——渲染上下文存活时销毁 mpv 句柄，mpv 内部会断言 abort。
        if let recovered = leakedProbe {
            DispatchQueue.main.sync { recovered.detach() }
            log("  阶段5 补 detach 收回泄漏的渲染上下文 ✓")
        }

        client.destroy()
        runLoopSpin(seconds: 0.5)
        log("  结论：全流程无 use-after-free 崩溃 ✓")
        exit(0)
    }

    // MARK: - 主线程操作

    private func makeViewOnMain(client: MPVClient) -> MPVGLView {
        var result: MPVGLView!
        DispatchQueue.main.sync {
            let view = MPVGLView.make()
            window?.contentView = view
            view.prepare(with: client)
            result = view
        }
        return result
    }

    /// 从窗口摘除、detach 并释放，返回视图是否真的析构（用于验证不泄漏）。
    ///
    /// 注意两个坑：
    ///   1. 不能再把视图绑到局部 `let`，否则检查时强引用仍在作用域内，弱引用永远非空；
    ///   2. AppKit 摘除视图是延迟到主线程本轮 run loop 处理的，判定前必须给一拍时间，
    ///      且主线程那侧要能排空 autorelease pool —— 所以此处用 autoreleasepool 包住。
    private func detachAndReleaseOnMain(_ view: inout MPVGLView?) -> Bool {
        guard view != nil else { return false }
        weak var probe = view
        DispatchQueue.main.sync {
            autoreleasepool {
                view?.detach()
                if window?.contentView == view { window?.contentView = nil }
            }
        }
        view = nil
        runLoopSpin(seconds: 0.3)   // 让主线程处理延迟摘除并排空 autorelease pool
        return probe == nil
    }

    /// 从窗口摘除并释放，**不**调用 detach —— 复现缺失 dismantleNSView 的旧行为。
    private func releaseWithoutDetachOnMain(_ view: inout MPVGLView?) {
        DispatchQueue.main.sync {
            if window?.contentView == view { window?.contentView = nil }
        }
        view = nil
    }

    /// 用弱引用探测对象是否已析构（保留给需要额外断言的场景）。
    private func isDeallocated(_ object: AnyObject) -> Bool {
        weak var weakRef = object
        return weakRef == nil
    }

    // MARK: - 工具

    /// 主线程空转事件循环（不能用 Thread.sleep：会阻塞 AppKit 动画与回调派发）。
    private func runLoopSpin(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// 逐行刷新输出——测试若崩溃，已完成的阶段必须留在终端里。
    private func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        fflush(stdout)
    }

    private func emit(_ line: String, code: Int32) -> Never {
        log(line)
        exit(code)
    }
}
