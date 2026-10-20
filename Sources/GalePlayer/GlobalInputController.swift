import AppKit
import SwiftUI

/// 窗口级事件捕获器：把滚轮 / 中键 / 拖放从「只有视频区域响应」变成**整个窗口都响应**。
///
/// 为什么需要它：
///   - 滚轮与中键原先挂在 `MPVGLView` 上，只有鼠标悬停在画面里才生效；
///     移到播放列表或控制栏上就没反应了。
///   - 拖放原先只有 `VideoStage` 的空状态占位接 `onDrop`，一旦开始播放画面就盖住了它；
///     而播放列表里的接收又是另一套语义（文件夹才扫描）。
///   两者统一到窗口层处理后：**窗口内任意位置**行为一致，
///   且文件夹一律按「扫描整个文件夹」处理，不再因落点不同而变。
///
/// 实现要点：NSView 默认只在鼠标**命中自己**时才收到事件，
/// 而我们要的是「窗口内任意处」——所以用一个铺满窗口的透明层，
/// 配合 `hitTest` 永不命中（让事件穿透到下层真正的控件），
/// 由 AppDelegate 在窗口层面直接分发 `NSEvent`。
@MainActor
final class GlobalInputController {
    static let shared = GlobalInputController()

    /// 已挂载监听器的窗口（用 identity 去重，避免同一个窗口反复挂）
    private var monitored: [ObjectIdentifier: NSWindow] = [:]
    private var monitors: [ObjectIdentifier: Any] = [:]

    /// 为一个窗口装上全局输入（可重复调用，内部去重）。
    func attach(to window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard monitors[key] == nil else { return }
        monitored[key] = window
        // addLocalMonitor 收到的是**应用级**事件，窗口内的滚动/中键都在其中；
        // 再用 event.window === window 过滤出「当前窗口」，从而对整个窗口生效。
        monitors[key] = NSEvent.addLocalMonitorForEvents(matching: [
            .scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp,
        ]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event, in: window) ?? event
        }
    }

    func detachAll() {
        monitors.values.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        monitored.removeAll()
    }

    /// 返回非 nil 表示事件已被消费；返回 nil 表示放行给下层控件。
    private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        guard event.window === window else { return nil }

        // 文本输入框里不抢（快捷键已是这个策略）
        if let responder = window.firstResponder, responder is NSTextView { return nil }

        switch event.type {
        case .scrollWheel:
            // 悬停在可滚动区域（播放列表 = SwiftUI List = NSScrollView）上时，
            // 滚轮要还给列表去滚动，不能拿去调音量 —— 否则滚动播放列表的同时
            // 音量也跟着变（用户实测反馈）。
            if isOverScrollableView(event, in: window) { return event }
            return handleScroll(event) ? nil : event
        case .otherMouseDown:
            middleDragStart(with: event)
            return nil
        case .otherMouseDragged:
            middleDragMove(with: event)
            return nil
        case .otherMouseUp:
            middleDragEnd()
            return nil
        default:
            return nil
        }
    }

    /// 光标下方的视图（或其祖先）是不是可滚动视图。
    ///
    /// 用命中测试向上找 `NSScrollView`，而不是按坐标猜「侧栏在哪」：
    /// 侧栏的可见性、宽度、全屏浮层都会变，按坐标判断会漏；
    /// 按视图类型判断则对现在和将来的任何可滚动区域都成立。
    private func isOverScrollableView(_ event: NSEvent, in window: NSWindow) -> Bool {
        isScrollableRegion(atWindowPoint: event.locationInWindow, in: window)
    }

    /// 测试钩子 / 判定单一来源：给定窗口坐标点，该点是否落在可滚动区域上。
    ///
    /// 抽出来单独成方法，是因为 `isOverScrollableView` 依赖 `NSEvent.locationInWindow`，
    /// 而滚轮事件在无头自检里无法合成（`otherEvent` 不接受 scrollWheel 类型、
    /// `CGEvent` 造出来的没有 window 关联），所以自检直接测这个判定函数。
    @MainActor
    func isScrollableRegion(atWindowPoint point: NSPoint, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let converted = contentView.convert(point, from: nil)
        var view: NSView? = contentView.hitTest(converted)
        while let current = view {
            if current is NSScrollView { return true }
            view = current.superview
        }
        return false
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let shift = event.modifierFlags.contains(.shift)
        let threshold = 0.5
        let wantsSeek = abs(deltaX) > abs(deltaY) || shift

        if wantsSeek {
            let delta = shift ? deltaY : deltaX
            guard abs(delta) >= threshold else { return false }
            NotificationCenter.default.post(
                name: .galeSeekWheel, object: nil,
                userInfo: ["delta": delta]
            )
            return true
        }
        guard abs(deltaY) >= threshold else { return false }
        NotificationCenter.default.post(
            name: .galeVolumeWheel, object: nil,
            userInfo: ["delta": deltaY]
        )
        return true
    }

    private var lastMiddleY: CGFloat?

    private func middleDragStart(with event: NSEvent) {
        lastMiddleY = event.locationInWindow.y
    }

    private func middleDragMove(with event: NSEvent) {
        let current = event.locationInWindow.y
        guard let previous = lastMiddleY else {
            lastMiddleY = current
            return
        }
        let delta = previous - current
        lastMiddleY = current
        guard delta != 0 else { return }
        NotificationCenter.default.post(
            name: .galeVolumeWheel, object: nil,
            userInfo: ["delta": delta * 6]     // 拖动位移放大到与滚轮同量级
        )
    }

    private func middleDragEnd() {
        lastMiddleY = nil
    }
}

extension Notification.Name {
    /// 窗口级滚轮请求调整音量（纵向滚轮 / 中键拖动）
    static let galeVolumeWheel = Notification.Name("com.kevin.galeplayer.volumeWheel")
    /// 窗口级滚轮请求跳转进度（横向滚轮 / ⇧+纵向）
    static let galeSeekWheel = Notification.Name("com.kevin.galeplayer.seekWheel")
}

/// 全屏下的「右缘感应」：鼠标贴近屏幕右侧时显示播放列表箭头；
/// 播放列表已展开时，鼠标离开一定距离后自动缩回。
///
/// 为什么不用 SwiftUI 的 `onHover`：全屏时视频区是 `MPVGLView`（NSOpenGLView），
/// 它在 AppKit 命中测试里会吃掉鼠标移动事件，`onHover` 收不到。
///
/// 为什么用**本地**监听而不是 `addGlobalMonitorForEvents`：
/// 全局监听需要「辅助功能」权限，没授权时**静默失效** ——
/// 表现为「鼠标贴到右缘但箭头永远不出现」。
/// 本地监听（`addLocalMonitorForEvents`）只处理送到本应用的事件，**不需要任何权限**；
/// 全屏时鼠标本来就在我们窗口上，够用。
@MainActor
final class EdgeRevealController: ObservableObject {
    static let shared = EdgeRevealController()

    /// 距屏幕右缘多近算「贴近」（pt）
    private let revealMargin: CGFloat = 56
    /// 已展开时，离开多远自动缩回（pt）
    private let collapseDistance: CGFloat = 140
    /// 缩回延迟（秒）：留一点缓冲，避免鼠标掠过时抖动
    private let collapseDelay: Double = 0.45

    /// 是否贴近右缘（驱动箭头显隐）
    @Published private(set) var isNearRightEdge = false
    /// 播放列表是否展开（由外部同步）
    var isPlaylistOpen = false
    /// 外部提供的收起回调
    var onShouldCollapse: (() -> Void)?

    private var monitor: Any?
    private var collapseTask: DispatchWorkItem?

    func start(window: NSWindow? = nil) {
        // 让窗口接收 mouseMoved（AppKit 默认不跟踪移动，除非显式打开）
        if let window {
            window.acceptsMouseMovedEvents = true
        } else {
            for w in NSApp.windows where w.isVisible { w.acceptsMouseMovedEvents = true }
        }

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            // 本地监听的回调在主线程；直接用 assumeIsolated 同步处理即可
            MainActor.assumeIsolated { self?.evaluate(event: event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        collapseTask?.cancel()
        collapseTask = nil
    }

    /// 测试钩子：直接设定「贴近右缘」，便于自检在不动真实鼠标的情况下验证箭头。
    func setNearRightEdgeForTesting(_ value: Bool) {
        if isNearRightEdge != value { isNearRightEdge = value }
    }

    private func evaluate(event: NSEvent) {
        guard let window = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let inWindow = event.locationInWindow
        let frameInWindow = window.contentView?.bounds ?? .zero
        let distanceFromRight = frameInWindow.maxX - inWindow.x
        let near = distanceFromRight <= revealMargin

        if near != isNearRightEdge { isNearRightEdge = near }

        guard isPlaylistOpen else { return }
        if near {
            collapseTask?.cancel()
            collapseTask = nil
        } else if distanceFromRight > collapseDistance {
            collapseTask?.cancel()
            let task = DispatchWorkItem { [weak self] in self?.onShouldCollapse?() }
            collapseTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: task)
        } else {
            collapseTask?.cancel()
            collapseTask = nil
        }
    }
}
