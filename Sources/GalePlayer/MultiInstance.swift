import AppKit

/// 多开实例：每个实例是一个**独立进程**（独立 mpv、独立窗口、独立播放列表视图）。
///
/// 相比在 app 层用 SwiftUI `WindowGroup` 硬造多窗口，多开实例省掉了全部窗口生命周期、
/// 焦点路由、快捷键分发的问题 —— 这些都由系统按「哪个进程在前台」天然处理好了。
///
/// 代价：多个实例共享同一批数据文件（playlist/chapters/history），写入已是原子写，
/// 跨实例的实时同步按「已知限制」处理（切到某实例时需要它自己刷新才看到别的实例改动）。
enum MultiInstance {
    /// 同时最多运行的实例数。
    static let maxInstances = 3

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }

    /// 当前正在运行的同类实例数量（含自己）。
    static func runningCount() -> Int {
        guard !bundleID.isEmpty else { return 1 }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
    }

    static var isAtLimit: Bool { runningCount() >= maxInstances }

    /// 发起一个新实例（独立进程）。返回是否真的发起（已达上限则不发）。
    @discardableResult
    static func spawn() -> Bool {
        guard !isAtLimit else { return false }
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("Gale: 新实例启动失败 \(error)") }
        }
        return true
    }

    /// 用**新实例**打开指定文件（播放列表右键「在新窗口打开」）。
    /// 新实例收到 open 事件后会把它加载进自己的窗口。
    @discardableResult
    static func openInNewInstance(_ url: URL) -> Bool {
        guard !isAtLimit else { return false }
        let appURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
            if let error { NSLog("Gale: 新窗口打开文件失败 \(error)") }
        }
        return true
    }
}
