import AppKit
import Foundation
import GaleCore

/// 播放进度记忆自检：真实走一遍「记录 → 落盘 → 重新读取 → 恢复」。
///
/// 用法：GalePlayer --resume-test <媒体文件> [位置秒]
enum ResumeTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--resume-test")
    }

    @MainActor
    static func start(core: PlayerCore?, settings: AppSettings?) {
        guard let core, let settings else {
            report("  失败：PlayerCore / AppSettings 未就绪")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            perform(core: core, settings: settings)
        }
    }

    private static func perform(core: PlayerCore, settings: AppSettings) {
        var lines: [String] = ["播放进度记忆自检"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--resume-test"), args.count > index + 1 else {
            report("用法: --resume-test <媒体文件> [位置秒]")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: args[index + 1])
        let target = args.count > index + 2 ? (Double(args[index + 2]) ?? 120) : 120

        // 清掉历史，从干净状态开始
        onMain { core.forgetProgress(for: mediaURL) }

        // 1) 打开文件并跳到目标位置
        onMain { core.open(urls: [mediaURL]) }
        let loadDeadline = Date().addingTimeInterval(25)
        while onMain({ core.duration }) <= 0, Date() < loadDeadline {
            spin(seconds: 0.4)
        }
        guard onMain({ core.duration }) > 0 else {
            report((lines + ["  失败：媒体未加载"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        lines.append("  已加载，时长 \(Int(onMain { core.duration })) 秒")

        // 等 timePos 真正到位再写进度
        onMain { core.seek(to: target) }
        let seekDeadline = Date().addingTimeInterval(5)
        while abs(onMain({ core.timePos }) - target) > 3, Date() < seekDeadline {
            spin(seconds: 0.3)
        }
        let reached = onMain { core.timePos }
        lines.append("  定位到 \(String(format: "%.1f", reached)) 秒（目标 \(Int(target))）")

        // 2) 落盘（退出路径就是走这个）
        onMain { core.flushProgress() }
        let historyFile = onMain { core.playbackHistoryURL }
        let exists = historyFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        lines.append("  进度文件=\(historyFile?.lastPathComponent ?? "?") 已写入=\(exists)")

        // 3) 从磁盘重新读一次（模拟「下次启动」），确认能读回
        guard let historyFile else {
            report((lines + ["  失败：拿不到进度文件路径"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        let fresh = PlaybackHistory.load(from: historyFile)
        let resumable = fresh.resumablePosition(for: mediaURL)
        lines.append("  重新读盘后可恢复位置=\(resumable.map { String(format: "%.1f", $0) } ?? "nil")")

        // 4) 让 PlayerCore 丢弃内存副本、只从磁盘重建（这正是「下次启动」走的路径）
        onMain { core.reseedHistoryFromDisk() }
        let afterReseed = onMain { core.resumablePosition(for: mediaURL) }
        lines.append("  App 从磁盘重建后可恢复=\(afterReseed.map { String(format: "%.1f", $0) } ?? "nil")")
        let reseedOK = afterReseed != nil && abs((afterReseed ?? 0) - (resumable ?? -1)) < 1

        // 5) 结论
        let ok = exists && (resumable != nil) && reseedOK
        lines.append(ok ? "  结论：进度已记录并可恢复 ✓" : "  结论：进度链路不完整 ✗")

        // 清理
        onMain { core.forgetProgress(for: mediaURL) }
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func spin(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}