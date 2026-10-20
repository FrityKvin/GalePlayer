import AppKit
import CMPV
import CoreVideo
import OpenGL.GL

/// 视频渲染视图：libmpv render API + NSOpenGLView。
///
/// 为什么必须这么做：mpv 0.39 起移除了 macOS 的 `wid`（NSView）嵌入支持，
/// 传入 `wid` 会被忽略，mpv 会另开一个独立窗口（表现为「播放时弹出一个新窗口」）。
/// macOS 上唯一正确的嵌入方式是宿主提供 GL 上下文、用 `mpv_render_context_render`
/// 自己驱动每一帧 —— IINA 走的也是这条路。
///
/// 线程约定：
///   - `mpv_render_context_*` 只在主线程、且 GL 上下文已置为 current 时调用；
///   - mpv 的更新回调来自 mpv 内部线程，只做一次主线程派发，不在该线程上碰任何状态。
///
/// `@unchecked Sendable`：NSView 只能主线程访问，这里靠上述约定保证，
/// 仅为让跨线程回调能把实例捕获进 `DispatchQueue.main.async`。
final class MPVGLView: NSOpenGLView, @unchecked Sendable {
    /// 是否让交换阻塞等 vsync。
    ///
    /// true（默认）：`flushBuffer` 阻塞到下一次 vsync，画面撕裂最少，
    /// 但**阻塞发生在主线程上**（每帧最多 16.7ms）→ 播放时 UI 发木。
    /// false：交换立即返回，帧交给窗口服务器合成，代价是理论上的撕裂可能。
    /// 用 `GALE_VSYNC=0/1` 覆盖便于实测对比。
    private static var swapIntervalPreference: Bool {
        switch ProcessInfo.processInfo.environment["GALE_VSYNC"] {
        case "0": return false
        case "1": return true
        default: return true
        }
    }

    /// 生命周期追踪：仅当 `GALE_TRACE=1` 时输出，用于排查视图重建时序。
    nonisolated(unsafe) static let traceEnabled = ProcessInfo.processInfo.environment["GALE_TRACE"] == "1"

    private func trace(_ message: String) {
        guard Self.traceEnabled else { return }
        NSLog("GaleTrace[\(String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16))] \(message)")
    }

    private var renderContext: OpaquePointer?
    private var pendingClient: MPVClient?
    private var isTearingDown = false


    /// 交给 mpv 的回调上下文指针，由 `passRetained` 产生 —— 即 mpv 侧对本视图的 +1 引用。
    /// 必须在 `detach()` 里对称释放一次，否则视图永不析构。
    private var callbackContext: UnsafeMutableRawPointer?

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// 滚轮：纵向 → 音量，横向（或 ⇧+纵向）→ 播放进度
    var onVolumeWheel: ((CGFloat) -> Void)?
    var onSeekWheel: ((CGFloat) -> Void)?
    /// 中键按住纵向拖动 → 音量
    var onMiddleDrag: ((CGFloat) -> Void)?

    private static let pixelFormatAttributes: [NSOpenGLPixelFormatAttribute] = [
        UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
        UInt32(NSOpenGLPFAColorSize), 24,
        UInt32(NSOpenGLPFAAlphaSize), 8,
        UInt32(NSOpenGLPFADoubleBuffer),
        UInt32(NSOpenGLPFAAccelerated),
        0,
    ]

    /// NSOpenGLView 的指定初始化器是 failable 的，故用工厂方法创建。
    static func make() -> MPVGLView {
        guard let format = NSOpenGLPixelFormat(attributes: pixelFormatAttributes) else {
            fatalError("无法创建 OpenGL 像素格式")
        }
        guard let view = MPVGLView(frame: .zero, pixelFormat: format) else {
            fatalError("无法创建视频视图")
        }
        return view
    }

    override init?(frame frameRect: NSRect, pixelFormat format: NSOpenGLPixelFormat?) {
        super.init(frame: frameRect, pixelFormat: format)
        wantsBestResolutionOpenGLSurface = true
        // 注意：不要给 NSOpenGLView 开 wantsLayer，会干扰 GL 表面
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - render API 生命周期（主线程）

    /// 记录 mpv 实例；等视图真正进窗口（GL 上下文定型）后再建渲染上下文。
    func prepare(with client: MPVClient) {
        trace("prepare(window=\(window != nil), ctx=\(renderContext != nil))")
        pendingClient = client
        if window != nil {
            createRenderContext(with: client)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trace("viewDidMoveToWindow(window=\(window != nil), ctx=\(renderContext != nil), pending=\(pendingClient != nil))")
        if window != nil, renderContext == nil, let pendingClient {
            createRenderContext(with: pendingClient)
        }
    }

    private func createRenderContext(with client: MPVClient) {
        guard renderContext == nil, let handle = client.mpvHandle else {
            trace("createRenderContext 跳过（ctx=\(renderContext != nil) handle=\(client.mpvHandle != nil)）")
            return
        }

        // 视图可能经历「拆卸后复用」：SwiftUI 重建时会把同一个 NSView 再交回来，
        // 此时必须复位拆卸标记，否则渲染回调会被 isTearingDown 永久挡掉（黑屏）。
        isTearingDown = false

        guard let glContext = openGLContext else {
            NSLog("Gale: 无 OpenGL 上下文，无法创建渲染上下文")
            return
        }
        glContext.makeCurrentContext()

        var initParams = mpv_opengl_init_params(
            get_proc_address: galeGetProcAddress,
            get_proc_address_ctx: nil
        )

        // API 类型字符串必须在调用期间保持有效
        guard let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL) else { return }
        defer { free(apiType) }

        var context: OpaquePointer?
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &initParams),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]

        let result = mpv_render_context_create(&context, handle, &params)
        guard result >= 0, let context else {
            NSLog("Gale: mpv_render_context_create 失败（\(result)）")
            return
        }
        renderContext = context

        // 关键：用 passRetained 而不是 passUnretained。
        //
        // passUnretained 交给 mpv 的只是一个裸地址，mpv 侧不持有引用；一旦 SwiftUI
        // 在回调仍注册时释放视图（历史崩溃 incident 5693B60E：objc_retain 命中已释放对象），
        // mpv 的 vo 线程就会在野指针上做 retain → EXC_BAD_ACCESS。
        // passRetained 让这个指针成为一次真实的 +1 引用，mpv 可以安全地长期持有它，
        // 由 detach() 负责对称释放（代价：漏掉 detach 会泄漏视图，用 dismantleNSView 兜住）。
        let callbackContext = Unmanaged.passRetained(self).toOpaque()
        self.callbackContext = callbackContext
        mpv_render_context_set_update_callback(context, galeRenderUpdate, callbackContext)

        trace("createRenderContext 成功（ctx 已就绪）")
    }

    /// 供自检使用的状态：渲染上下文是否已就绪（未就绪通常意味着创建撞车 -20）。
    var hasRenderContext: Bool { renderContext != nil }

    /// 释放渲染上下文。必须在销毁 mpv 句柄之前、GL 上下文 current 时调用。
    ///
    /// 注意：**不要**在这里清掉 `pendingClient`。SwiftUI 会在同一个事务里先拆卸、
    /// 再把同一个 NSView 复用回去（实测 trace：视图先 prepare、再被拆卸、然后才进窗口），
    /// 清掉绑定会让它在 `viewDidMoveToWindow` 时拿不到 mpv 实例 → 渲染上下文永远建不起来
    /// （表现为「切一次全屏后画面不再渲染」，且不报 -20，因为压根没尝试创建）。
    func detach() {
        trace("detach() 被调用（ctx=\(renderContext != nil)）")
        guard !isTearingDown else { return }
        isTearingDown = true

        if let renderContext {
            openGLContext?.makeCurrentContext()
            // 先注销回调 —— 此后 mpv 保证不会再回调，才可以安全释放视图引用。
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
        }
        renderContext = nil

        // 对称释放 mpv 侧那次 +1。放在最后：这一步可能触发本视图析构。
        if let callbackContext {
            self.callbackContext = nil
            Unmanaged<MPVGLView>.fromOpaque(callbackContext).release()
        }
    }

    deinit {
        // 不需要兜底释放：`callbackContext` 持有的是 passRetained 产生的 +1 引用，
        // 只要回调还注册着，本视图就不可能被析构；而回调只在 detach() 里注销，
        // 那里同时也把 renderContext 置空并释放了 +1。因此走到 deinit 时
        // renderContext 必为 nil —— 不存在「析构时仍有未拆卸上下文」的状态。
    }

    // MARK: - 交互

    override var acceptsFirstResponder: Bool { true }

    // 滚轮与中键已上移到 `GlobalInputController`（窗口级）。
    // 这里保留钩子是为了兼容旧调用点，但**不再自己处理**，
    // 否则窗口级监听与视图级会各处理一次 → 音量/进度翻倍跳。

    /// 单击 = 播放/暂停，双击 = 进出全屏（暴风影音同款）。
    ///
    /// 双击的第一次 mouseUp（clickCount == 1）必须**延后**一小会儿再决定：
    /// 否则双击会先触发一次「播放/暂停」，再进全屏 —— 表现为双击后播放状态被反转。
    private var pendingSingleClick: DispatchWorkItem?
    private static let doubleClickWindow: TimeInterval = 0.25

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            RenderMetrics.doubleClicks += 1
            onDoubleClick?()
            return
        }

        // 单击：等一等，看会不会变成双击
        pendingSingleClick?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingSingleClick = nil
            RenderMetrics.singleClicks += 1
            self?.onClick?()
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.doubleClickWindow,
            execute: work
        )
    }

    // MARK: - 绘制
    //
    // 线程模型：**单线程渲染**（主线程）。
    //
    // 曾经试过「CVDisplayLink + 独立渲染线程 + 离屏 FBO」以彻底放开主线程，
    // 但实测在 AppKit 的 NSOpenGLView 上不可行，两次都崩在 Metal/OpenGL 层：
    //   17:00:38 CVDisplayLink 线程 → AppleMetalOpenGLRenderer
    //          GLDTextureRec::getTextureResource（drawable 属主线程，跨线程取纹理）
    //   17:05:41 CVDisplayLink 线程 → IOGPU assert
    //          "commit command buffer with uncommitted encoder"（与主线程共用同一 GL 上下文）
    // NSOpenGLView 的 drawable 与 GL 上下文都不是线程安全的，
    // 跨线程渲染必须同时换成自建 CGL 上下文 + 自管 drawable，属于另一套架构。
    //
    // 真正要解决的是「别让主线程替 mpv 等帧」，那个用 mpv_render_context_update()
    // 就能做到 —— 它取的是快照，不会阻塞。

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        RenderMetrics.swapInterval = 1
    }

    override func draw(_ dirtyRect: NSRect) {
        render()
    }

    override func reshape() {
        super.reshape()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    func render() {
        guard let renderContext, let glContext = openGLContext, !isTearingDown else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }

        glContext.makeCurrentContext()

        // **关键**：`mpv_render_context_update()` 先问 mpv 有没有新帧 / 要不要重画。
        // 它只是读状态快照，不会等待。
        //
        // 老实现直接调 `mpv_render_context_render`，mpv 会为等下一帧解码完成而阻塞
        // （实测 12 秒里主线程有 4.2 秒停在 libmpv 的 _pthread_cond_wait，
        //  约合墙钟 35%，表现为播放时 UI 发木）。改为先查询之后，
        // 主线程只在真有新帧时才进入一次短暂的渲染。
        let flags = mpv_render_context_update(renderContext)
        guard flags != 0 else { return }

        let scale = window?.backingScaleFactor ?? 2
        var fbo = mpv_opengl_fbo(
            fbo: 0,
            w: Int32(bounds.width * scale),
            h: Int32(bounds.height * scale),
            internal_format: 0
        )
        var flip: Int32 = 1

        // 关键：让 mpv **不要**在 render 里阻塞等目标显示时间。
        //
        // 默认（=1）时 mpv 会提前渲染一点然后阻塞等到该上屏的时刻，
        // 这个等待发生在**调用方线程**（我们这里是主线程），
        // 实测 12 秒里主线程有 4.2 秒停在 libmpv 的 _pthread_cond_wait
        // → 播放时 UI 发木（主线程最大延迟 32ms、每秒 6 次卡顿）。
        //
        // mpv 文档对关掉它的说明是：改用 mpv_render_frame_info 里的
        // target_time 自己等，否则 A/V 同步会略偏。下面正是这么做的。
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fbo),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flip),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]

        let renderStart = DispatchTime.now()
        mpv_render_context_render(renderContext, &params)

        let flushStart = DispatchTime.now()
        glContext.flushBuffer()
        let flushElapsed = Double(DispatchTime.now().uptimeNanoseconds - flushStart.uptimeNanoseconds) / 1e6

        mpv_render_context_report_swap(renderContext)


        RenderMetrics.framesPresented &+= 1
        RenderMetrics.flushSeconds += flushElapsed / 1000
        if flushElapsed > RenderMetrics.maxFlushBlockMS {
            RenderMetrics.maxFlushBlockMS = flushElapsed
        }
        RenderMetrics.renderSeconds += Double(
            DispatchTime.now().uptimeNanoseconds - renderStart.uptimeNanoseconds
        ) / 1e9
    }

    /// mpv 更新回调（mpv 内部线程）→ 只派发一次主线程渲染。
    ///
    /// 真正决定「要不要画」的是 `render()` 里的 `mpv_render_context_update()`，
    /// 这里无条件唤醒即可 —— 多唤醒的代价只是一次状态检查。
    fileprivate func requestRenderFromMPVThread() {
        DispatchQueue.main.async { [self] in
            guard !isTearingDown else { return }
            render()
        }
    }

}

// MARK: - C 回调

/// 向 libmpv 提供 GL 函数地址（macOS 上 OpenGL 符号在 com.apple.opengl 里）。
private func galeGetProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    let symbol = String(cString: name)
    guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
    return CFBundleGetFunctionPointerForName(bundle, symbol as CFString)
}

/// mpv 渲染更新回调（mpv 内部线程）。
private func galeRenderUpdate(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let view = Unmanaged<MPVGLView>.fromOpaque(ctx).takeUnretainedValue()
    view.requestRenderFromMPVThread()
}
