import AppKit
import Foundation

/// 无界面自检：真实走一遍 mpv 加载 → 解码 → 渲染路径，输出证据。
///
/// 用途：
///   - 验证内核集成（RMVB / HEVC 10bit / AV1 是否真能解出画面）
///   - 回归测试：换 libmpv 版本（例如路线 A → B 切 LGPL 构建）后跑一次
///
/// 用法：
///   GalePlayer --diagnose <媒体文件> [--shot 输出.png] [--profile vulkan|opengl|opengl-legacy]
///
/// 关键点：必须真正运行 NSApplication 事件循环。mpv 的 macOS 渲染层
/// （cocoa-cb / CAMetalLayer）要等窗口层准备就绪才继续 VO 初始化，
/// 若主线程被阻塞或未跑 run loop，就会永远卡在创建渲染表面那一步。
enum Diagnostics {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--diagnose")
    }

    static func run() -> Never {
        let delegate = DiagnosticDelegate(arguments: CommandLine.arguments)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

final class DiagnosticDelegate: NSObject, NSApplicationDelegate {
    private let arguments: [String]
    private var window: NSWindow?
    private var view: NSView?

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let flagIndex = arguments.firstIndex(of: "--diagnose"),
              arguments.count > flagIndex + 1 else {
            FileHandle.standardError.write(Data("用法: --diagnose <媒体文件> [--shot 输出.png]\n".utf8))
            exit(64)
        }
        let filePath = arguments[flagIndex + 1]
        let shotPath = Self.value(of: "--shot", in: arguments)
        let profile = Self.value(of: "--profile", in: arguments) ?? "default"

        // 窗口必须在主线程创建；随后的等待/采集放到后台，主线程继续跑事件循环
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 1280, height: 720),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = MPVGLView.make()
        window.contentView = view
        window.title = "Gale 自检"
        window.orderFront(nil)
        self.window = window
        self.view = view

        DispatchQueue.global(qos: .userInitiated).async { [view] in
            Self.performDiagnosis(
                file: filePath,
                shot: shotPath,
                profile: profile,
                view: view
            )
        }
    }

    // MARK: - 自检主体（后台线程；mpv API 本身线程安全）

    private static func performDiagnosis(file: String, shot: String?, profile: String, view: MPVGLView) {
        var extraOptions: [String: String] = [:]
        switch profile {
        case "opengl":
            extraOptions["vo"] = "libmpv"
            extraOptions["gpu-api"] = "opengl"
        case "swiftshader":
            extraOptions["vo"] = "libmpv"
        default:
            break
        }

        guard let client = MPVClient(verbose: true, extraOptions: extraOptions) else {
            emit(["status": "error", "error": "mpv_create/initialize failed", "profile": profile])
            exit(2)
        }

        // 渲染上下文必须在主线程、GL 上下文可用后创建
        DispatchQueue.main.async {
            view.prepare(with: client)
        }
        Thread.sleep(forTimeInterval: 1.0)

        let loaded = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        client.onEvent = { event in
            switch event {
            case "file-loaded": loaded.signal()
            case "eof", "end-file": ended.signal()
            default: break
            }
        }

        var report: [String: String] = [
            "file": URL(fileURLWithPath: file).lastPathComponent,
            "libmpv": client.getString("mpv-version") ?? "unknown",
            "ffmpeg": client.getString("ffmpeg-version") ?? "unknown",
            "profile": profile,
        ]

        client.loadFile(URL(fileURLWithPath: file))

        if loaded.wait(timeout: .now() + 40) == .timedOut {
            report["status"] = "timeout"
            report["error"] = "40 秒内未收到 file-loaded"
            emit(report)
            exit(3)
        }
        report["status"] = "loaded"

        // 等若干帧真正渲染出来
        _ = ended.wait(timeout: .now() + 2.5)

        report["vo"] = client.getString("current-vo") ?? ""
        report["gpu-api"] = client.getString("gpu-api") ?? ""
        report["duration"] = client.getDouble("duration").map { String(format: "%.2f", $0) } ?? ""
        report["resolution"] = "\(client.getString("width") ?? "?")x\(client.getString("height") ?? "?")"
        report["video-codec"] = client.getString("video-codec") ?? ""
        report["audio-codec"] = client.getString("audio-codec") ?? ""
        report["hwdec-current"] = client.getString("hwdec-current") ?? "(none)"
        report["pixfmt"] = client.getString("video-params/pixelformat") ?? ""
        report["dropped-frames"] = client.getString("frame-drop-count") ?? ""
        report["decoded-frames"] = client.getString("decoder-frame-drop-count") ?? ""

        if let shot {
            client.screenshot(to: shot)
            Thread.sleep(forTimeInterval: 1.0)
            let exists = FileManager.default.fileExists(atPath: shot)
            let size = (try? FileManager.default.attributesOfItem(atPath: shot)[.size] as? Int) ?? nil
            report["screenshot"] = exists ? "\(shot) (\(size ?? 0) bytes)" : "FAILED"
        }

        // 窗口数量：验证 mpv 是嵌进我们给的 NSView，还是自己另开了一个窗口
        DispatchQueue.main.sync {
            let windows = NSApplication.shared.windows
            report["app-window-count"] = "\(windows.count)"
            report["app-windows"] = windows.map { window in
                let kind = String(describing: type(of: window))
                let visible = window.isVisible ? "visible" : "hidden"
                return "\(kind)/\(window.title)/\(Int(window.frame.width))x\(Int(window.frame.height))/\(visible)"
            }.joined(separator: " | ")
        }

        emit(report)
        exit(0)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
        return arguments[index + 1]
    }

    private static func emit(_ report: [String: String]) {
        let ordered = report.sorted { $0.key < $1.key }
        var text = "{\n"
        for (index, entry) in ordered.enumerated() {
            text += "  \"\(entry.key)\": \"\(entry.value)\""
            text += index == ordered.count - 1 ? "\n" : ",\n"
        }
        text += "}\n"
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
