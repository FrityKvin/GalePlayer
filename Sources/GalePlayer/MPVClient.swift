import AppKit
import CMPV
import Foundation

/// mpv 属性值（仅覆盖本项目使用到的类型）。
enum MPVValue: Sendable {
    case double(Double)
    case int(Int64)
    case flag(Bool)
    case string(String)
    case none

    var doubleValue: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        case .flag(let v): v ? 1 : 0
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .flag(let v): v
        case .int(let v): v != 0
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

/// libmpv 客户端封装。
///
/// 纪律（关系到将来的许可证切换，见路线 A/B）：
///   - 只通过公开的 libmpv C API 调用，不静态链接、不复制任何 GPL 源码进来；
///   - 内核以动态库形式加载（brew 的 `libmpv.dylib`），将来换成自建 LGPL 版
///     只需要替换 dylib，业务代码零改动。
final class MPVClient: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "com.kevin.galeplayer.mpv.events", qos: .userInitiated)
    private let stateLock = NSLock()
    private var terminated = false

    /// 属性变化回调（在 mpv 事件线程调用，使用方自行切回主线程）。
    var onProperty: (@Sendable (String, MPVValue) -> Void)?
    /// 事件回调：`file-loaded` / `eof` / `end-file`。
    var onEvent: (@Sendable (String) -> Void)?

    /// 等待文件加载完成后要执行的定位（关键帧跳转/续播用）。
    private var pendingSeek: Double?

    private static let observedProperties: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("media-title", MPV_FORMAT_STRING),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("core-idle", MPV_FORMAT_FLAG),
    ]

    // MARK: - 生命周期

    /// - Parameter verbose: 打开 mpv 终端日志（自检/排障用）。
    /// - Parameter extraOptions: 额外 mpv 选项（渲染后端等实验用）。
    ///
    /// 注意：不使用 `wid`。mpv 0.39 起移除了 macOS 的 NSView 嵌入（旧 cocoa 后端被删），
    /// `wid` 会被忽略并导致 mpv 自开一个独立窗口。macOS 上唯一正确的嵌入方式是
    /// libmpv render API（`vo=libmpv` + `mpv_render_context_*`），由 `MPVGLView` 驱动。
    init?(verbose: Bool = false, extraOptions: [String: String] = [:]) {
        guard let handle = mpv_create() else { return nil }
        self.handle = handle

        setOption("terminal", verbose ? "yes" : "no")
        if verbose {
            setOption("msg-level", "all=v")
            setOption("log-file", "/tmp/gale-mpv.log")
        }
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("osc", "no")
        setOption("config", "no")
        setOption("load-scripts", "no")
        setOption("ytdl", "no")
        setOption("keep-open", "no")
        setOption("idle", "yes")
        // render API：由宿主提供 GL 上下文并驱动绘制，mpv 不创建窗口
        setOption("vo", "libmpv")
        setOption("gpu-api", "opengl")
        // auto-copy-safe：仍走 VideoToolbox 硬解，但优先 copy-back 变体。
        // 纯零拷贝的 videotoolbox 会让 mpv 的截图路径失败
        // （"Input image format videotoolbox not supported by libswscale"），
        // 而本应用有截图功能（⇧F5，对应暴风原版行为），所以选择可回读的硬解。
        // 硬件解码：优先零拷贝，失败自动降级到拷贝模式。
        //
        // mpv 的 hwdec 支持逗号分隔的降级链（实测 0.41 生效：
        // 首选 videotoolbox，不可用则自动退到 videotoolbox-copy / 软解）。
        // 实测 4K H.264：零拷贝 CPU 8.6% vs 拷贝 15.8%，内存 416MB vs 470MB，
        // 1080p 及以下两者几乎无差别（差 0.3 个百分点），因此默认优先零拷贝。
        let hwdec = ProcessInfo.processInfo.environment["GALE_HWDEC"]
            ?? "videotoolbox,auto-copy-safe"
        setOption("hwdec", hwdec)
        setOption("sub-auto", "fuzzy")           // 自动加载同名字幕，对应暴风 autoLoadSubtitle
        setOption("sub-file-paths", "sub,subs,subtitles:.")
        setOption("screenshot-format", "png")
        setOption("screenshot-tag-colorspace", "yes")
        setOption("volume-max", "200")

        // 内存：限制解复用器的读取缓存。mpv 默认 demuxer-max-bytes=150MiB，
        // 对本地文件是纯浪费（实测播放一个 58MB 的文件时占用 220MB）。
        // 32MiB 对本地文件足够（顺序读取即可），网络流仍能保证流畅。
        setOption("demuxer-max-bytes", "32MiB")

        // 视频时序：把渲染提前量设为 0。
        //
        // 默认 mpv 会「提前渲染一点、再阻塞等到该上屏的时刻」，
        // 这个阻塞发生在调用方线程（我们的主线程）上 ——
        // 实测 12 秒里主线程 4.2 秒停在 libmpv 的 _pthread_cond_wait。
        // video-timing-offset 就是这个提前量，设为 0 后 mpv 不再提前等，
        // 帧只在该显示的时刻渲染，主线程因此不再被阻塞，
        // 同时 A/V 同步仍由 mpv 内部时序保证（不依赖手工补偿）。
        setOption("video-timing-offset", "0")
        setOption("cache-secs", "30")
        setOption("audio-client-name", "Gale")
        setOption("title", "Gale")

        for (key, value) in extraOptions {
            setOption(key, value)
        }

        let initResult = mpv_initialize(handle)
        guard initResult >= 0 else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            return nil
        }

        // mpv 0.41 起 mpv_observe_property 去掉了 data 参数
        for (name, format) in Self.observedProperties {
            mpv_observe_property(handle, 0, name, format)
        }

        eventQueue.async { [weak self] in self?.runEventLoop() }
    }

    deinit {
        destroy()
    }

    /// 非阻塞销毁。
    ///
    /// 这里**绝不能** `eventQueue.sync`：mpv 的 macOS 渲染层跑在主线程，主线程等事件线程
    /// 会与「事件线程等主线程」形成死锁 —— 那就是 ⌘Q 卡死的根因。
    /// 改成把销毁排到事件队列尾部：事件循环因 `terminated` 标志退出后，该块才会执行。
    func destroy() {
        stateLock.lock()
        if terminated {
            stateLock.unlock()
            return
        }
        terminated = true
        let handleToDestroy = handle
        handle = nil
        stateLock.unlock()

        guard let handleToDestroy else { return }
        eventQueue.async {
            mpv_terminate_destroy(handleToDestroy)
        }
    }

    /// 供 libmpv render API 创建渲染上下文使用。
    var mpvHandle: OpaquePointer? { handle }

    private var isTerminated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return terminated
    }

    // MARK: - 事件循环

    private func runEventLoop() {
        while !isTerminated {
            guard let handle else { return }
            guard let eventPointer = mpv_wait_event(handle, 0.2) else { return }
            let event = eventPointer.pointee

            switch event.event_id {
            case MPV_EVENT_NONE:
                continue
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let raw = event.data else { continue }
                let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let namePointer = property.name else { continue }
                let name = String(cString: namePointer)
                onProperty?(name, Self.decode(property))
            case MPV_EVENT_FILE_LOADED:
                if let seek = pendingSeek {
                    pendingSeek = nil
                    setDouble("time-pos", seek)
                }
                onEvent?("file-loaded")
            case MPV_EVENT_END_FILE:
                if let raw = event.data {
                    let endFile = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    onEvent?(endFile.reason == MPV_END_FILE_REASON_EOF ? "eof" : "end-file")
                } else {
                    onEvent?("end-file")
                }
            default:
                break
            }
        }
    }

    private static func decode(_ property: mpv_event_property) -> MPVValue {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_INT64:
            return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_FLAG:
            return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_STRING:
            guard let pointer = data.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self).pointee else {
                return .string("")
            }
            return .string(String(cString: pointer))
        default:
            return .none
        }
    }

    // MARK: - 指令

    private func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_option_string(handle, name, value)
    }

    @discardableResult
    func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var cArguments: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        defer {
            for pointer in cArguments {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        cArguments.append(nil)
        return cArguments.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
        }
    }

    /// mpv 的单调时钟（微秒）。
    ///
    /// `mpv_render_frame_info.target_time` 用的是**这个**时钟，不是系统 uptime，
    /// 拿 uptime 去减会算出完全错误的剩余时间，所以必须向 mpv 要。
    func monotonicMicros() -> Int64 {
        guard let handle else { return 0 }
        // 符号名是 mpv_get_time_us（不是 mp_get_time_us）。
        // client.h 末尾那批 `#define mpv_get_time_us pfn_mpv_get_time_us`
        // 只在动态加载分支生效，静态链接下真实导出的就是 mpv_get_time_us。
        return mpv_get_time_us(handle)
    }

    /// 同步读取当前播放位置（不经属性回调）。自检/排障用。
    ///
    /// `time-pos` 在某些状态下用 DOUBLE 读会返回 PROPERTY_UNAVAILABLE，
    /// 因此再退回字符串形式解析。
    func currentTimePos() -> Double? {
        if let value = getDouble("time-pos") { return value }
        if let raw = getString("time-pos") { return Double(raw) }
        return nil
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    func getDouble(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value = 0.0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    func getString(_ name: String) -> String? {
        guard let handle else { return nil }
        guard let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func getFlag(_ name: String) -> Bool? {
        guard let handle else { return nil }
        var value: Int32 = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return nil }
        return value != 0
    }

    // MARK: - 播放控制

    func loadFile(_ url: URL, startAt: Double? = nil) {
        pendingSeek = startAt
        command(["loadfile", url.path, "replace"])
    }

    func stop() {
        pendingSeek = nil
        command(["stop"])
    }

    func togglePause() {
        command(["cycle", "pause"])
    }

    func setPaused(_ paused: Bool) {
        setFlag("pause", paused)
    }

    func seek(to seconds: Double) {
        setDouble("time-pos", max(0, seconds))
    }

    /// 跳到指定绝对位置（已由调用方夹好范围）。
    ///
    /// 曾经的 bug：`mpv_command(["seek", "-3.0", "relative+exact"])` 里负数以 "-" 开头，
    /// 被 mpv 的选项解析当成命令标志而报错 —— **相对跳转静默失效**（← → 从来没生效过）。
    /// 现在相对跳转由 `PlayerCore` 用已知播放位置换算成绝对位置，这里只写 property。
    func seek(toAbsolute seconds: Double) {
        setDouble("time-pos", max(0, seconds))
    }

    func setVolume(_ value: Double) {
        setDouble("volume", min(max(0, value), 200))
    }

    func setMuted(_ muted: Bool) {
        setFlag("mute", muted)
    }

    func setSpeed(_ value: Double) {
        setDouble("speed", min(max(0.1, value), 8))
    }

    func setAudioTrack(_ id: Int64) {
        var v = id
        guard let handle else { return }
        mpv_set_property(handle, "aid", MPV_FORMAT_INT64, &v)
    }

    func setSubtitleTrack(_ id: Int64) {
        var v = id
        guard let handle else { return }
        mpv_set_property(handle, "sid", MPV_FORMAT_INT64, &v)
    }

    func screenshot(to path: String) {
        setString("screenshot-format", "png")
        command(["screenshot-to-file", path, "video"])
    }

    func audioTracks() -> [(Int64, String)] {
        trackList("audio")
    }

    func subtitleTracks() -> [(Int64, String)] {
        trackList("sub")
    }

    private func trackList(_ type: String) -> [(Int64, String)] {
        guard let handle else { return [] }
        var node = mpv_node()
        guard mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &node) >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }

        var result: [(Int64, String)] = []
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else { return [] }
        for index in 0..<Int(list.pointee.num) {
            let item = list.pointee.values[index]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list else { continue }
            var id: Int64 = 0
            var typeName = ""
            var title = ""
            for entry in 0..<Int(map.pointee.num) {
                guard let key = map.pointee.keys[entry] else { continue }
                let name = String(cString: key)
                let value = map.pointee.values[entry]
                switch name {
                case "id": id = value.u.int64
                case "type": typeName = value.u.string.map { String(cString: $0) } ?? ""
                case "title": title = value.u.string.map { String(cString: $0) } ?? ""
                case "lang": if title.isEmpty { title = value.u.string.map { String(cString: $0) } ?? "" }
                default: break
                }
            }
            if typeName == type {
                result.append((id, title.isEmpty ? "轨道 \(id)" : title))
            }
        }
        return result
    }
}
