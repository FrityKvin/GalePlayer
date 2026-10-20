import AppKit
import SwiftUI
import GaleCore

/// 处理文件关联打开（双击视频 → 直接播放）、全屏状态同步与退出清理。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 `GaleApp` 在启动时注入。
    @MainActor static weak var core: PlayerCore?
    @MainActor static weak var settings: AppSettings?

    /// 全屏状态监听（安装一次，常驻）。用 NSLock 保护幂等安装。
    private static let installLock = NSLock()
    private nonisolated(unsafe) static var fullScreenObserver: FullScreenObserver?

    static func installFullScreenObserver() {
        installLock.lock()
        defer { installLock.unlock() }
        guard fullScreenObserver == nil else { return }
        fullScreenObserver = FullScreenObserver()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动时自动检查更新（24 小时最多一次，失败静默）。
        // 只有「无参数的正常启动」才检查：自检模式（--diagnose 等）都带标志，
        // 里面不能夹带网络请求，否则自检结果不可复现。
        if ProcessInfo.processInfo.arguments.count == 1 {
            UpdateChecker.shared.autoCheckIfNeeded()
        }

        // 窗口级输入：滚轮/中键对**整个窗口**生效（原先只在视频画面上）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            GlobalInputController.shared.attach(to: window)
        }
        for window in NSApp.windows where window.isVisible {
            GlobalInputController.shared.attach(to: window)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppDelegate.core?.open(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 显式声明「立即退出」。
    ///
    /// 之前没有实现，默认就是 terminateNow；这里写出来是为了把退出路径固定下来，
    /// 避免将来有人加了「有未保存内容就取消退出」的逻辑后，⌘Q 变成没反应。
    /// 另外保证 `HotKeyMonitor` 不会吞掉 ⌘Q（它对 ⌘Q 显式放行）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 先把进度落盘再拆 mpv（拆完就拿不到 time-pos / duration 了）
            AppDelegate.core?.flushProgress()
            AppDelegate.core?.detach()
            AppDelegate.settings?.prepareForExit()
        }
    }
}

/// 监听窗口全屏状态，回写给 `PlayerCore`，驱动 SwiftUI 在
/// 普通布局与全屏纯画面布局之间切换（AppKit 才有这个通知，SwiftUI 没有）。
///
/// 两条腿走路，因为通知这一条**实测不可靠**：
/// 从终端启动（应用非活动）时，窗口 `styleMask.fullScreen` 位已为真、画面确实进了全屏，
/// 但 `didEnterFullScreenNotification` 根本不发 —— 只靠通知会让全屏布局永不激活，
/// 表现为「全屏播放时界面上还留着侧栏和控制条」（用户实测反馈）。
/// 因此额外用低频轮询读取窗口自身的全屏位作为权威来源。
final class FullScreenObserver: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: DispatchSourceTimer?

    /// 自检用：轮询实际执行次数与最近一次读到的窗口全屏位。
    nonisolated(unsafe) static var debugPollCount = 0
    nonisolated(unsafe) static var debugLastSeen = false

    init() {
        let enter = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.core?.setFullScreen(true)
            }
        }

        let exit = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.core?.setFullScreen(false)
            }
        }
        observers = [enter, exit]

        // 权威来源：直接读播放窗口的 styleMask.fullScreen 位。
        //
        // 两个坑（都是实测踩出来的）：
        //   1. 必须用 DispatchSourceTimer 而不是 Timer —— Timer 依赖 run loop 模式，
        //      全屏转场期间会停摆（实测轮询计数直接冻结）。
        //   2. 必须跳过 AppKit 的内部窗口 —— 全屏转场期间会存在
        //      `_NSFullScreenTransitionOverlayWindow` 且 isVisible=true，
        //      简单取 windows.first(where: isVisible) 会拿到它，全屏位永远是 false。
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        timer.setEventHandler {
            // handler 已固定在主队列上，因此可断言主 actor 语义（无需再派发一次）
            MainActor.assumeIsolated {
                Self.debugPollCount += 1
                guard let window = Self.playerWindow() else { return }
                let inFullScreen = window.styleMask.contains(.fullScreen)
                Self.debugLastSeen = inFullScreen
                AppDelegate.core?.setFullScreen(inFullScreen)
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// 供自检/内部使用：读播放窗口的 styleMask 全屏位（与轮询回调同一套判定逻辑）。
    @MainActor
    static func currentWindowInFullScreen() -> Bool {
        playerWindow()?.styleMask.contains(.fullScreen) ?? false
    }

    /// 找出真正的播放窗口：排除 AppKit 内部窗口（`_NS...`）与无标题的辅助窗口。
    @MainActor
    private static func playerWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, !isInternalWindow(key) { return key }
        if let main = NSApp.mainWindow, !isInternalWindow(main) { return main }
        return NSApp.windows.first { $0.isVisible && !isInternalWindow($0) && !$0.title.isEmpty }
    }

    @MainActor
    private static func isInternalWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).hasPrefix("_NS")
    }

    deinit {
        pollTimer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
