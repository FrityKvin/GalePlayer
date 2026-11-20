import Foundation

/// 数据目录解析：把「真实运行」与「自检运行」彻底分流。
///
/// ## 事故背景（2026-11-20）
/// 自检（`--missing-file-test` 等）内部会调用 `settings.clearPlaylist()` 等
/// 写操作，而 AppSettings 指向**真实**的 `~/Library/Application Support/com.kevin.galeplayer/`。
/// 结果：跑一次自检就把用户的真实播放列表清空了。
///
/// ## 修复原则
/// 数据目录**按运行模式分流**，在唯一的入口（GaleApp.init）决定：
///   - 真实启动 → `<Application Support>/com.kevin.galeplayer/`
///   - 任一自检 flag → 进程唯一的一次性临时目录（退出即清理）
///   - `GALE_DATA_DIR` 显式覆盖 → 尊重它，并视为隔离（永不写真实目录）
///
/// 这样任一自检（包括将来新加的）都不会碰到用户数据 —— 不需要每个自检
/// 各自记得「别清空真实列表」，把约束收敛到一处。
public enum DataPaths {

    /// 已知的自检参数。新增自检时必须登记到这里（`DataPathsTests` 会逐一校验）。
    public static let selfTestFlags: Set<String> = [
        "--diagnose", "--hotkeys", "--list-folder", "--lifecycle-test",
        "--update-check", "--perf-test", "--window-report", "--menu-test",
        "--input-test", "--mouse-test", "--ui-rebuild-test", "--resume-test",
        "--highlight-test", "--folder-highlight-test", "--playlist-export-test",
        "--scroll-conflict-test", "--missing-file-test", "--folder-resync-test",
        "--transform-test", "--hit-test-report", "--resource-test",
        "--volume-latency-test",
    ]

    /// 真实数据目录名（= bundle id）。
    public static let realDirectoryName = "com.kevin.galeplayer"

    public struct Resolved {
        /// 实际使用的数据目录。
        public let directory: URL
        /// 是否处于隔离模式（临时目录 / 显式覆盖）。
        public let isIsolated: Bool
        /// 进程退出时是否该删除该目录。
        public let shouldCleanupOnExit: Bool
    }

    /// 解析数据目录（纯函数，便于单测）。
    ///
    /// - Parameters:
    ///   - arguments: 进程启动参数（含 argv[0]）。
    ///   - environment: 环境变量。
    public static func resolve(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolved {
        // ① 显式覆盖优先：用于把自检导到指定目录（CI / 调试）
        if let override = environment["GALE_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return Resolved(directory: dir, isIsolated: true, shouldCleanupOnExit: false)
        }

        // 自检参数 → 进程唯一的一次性临时目录
        if isSelfTest(arguments) {
            // 先兜底清理上次 kill -9 遗留的旧目录，再建本进程的
            sweepStaleDirectories()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("gale-selftest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return Resolved(directory: dir, isIsolated: true, shouldCleanupOnExit: true)
        }

        // ③ 普通启动 → 真实目录
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent(realDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Resolved(directory: dir, isIsolated: false, shouldCleanupOnExit: false)
    }

    /// 是否处于自检模式。
    ///
    /// 只认**完整参数**是已知 flag 的情况：用户双击一个名叫 `--mouse-test.mp4`
    /// 的文件时，参数是那个路径，不是裸 flag —— 不能误判（误判会让真实会话
    /// 用上临时目录，用户会以为数据全丢了）。
    public static func isSelfTest(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        // 从第 1 个参数开始（argv[0] 是路径）
        for arg in arguments.dropFirst() where selfTestFlags.contains(arg) {
            return true
        }
        return false
    }

    /// 清理一次性的自检目录（进程退出时调用）。
    public static func cleanupIfNeeded(_ resolved: Resolved) {
        guard resolved.shouldCleanupOnExit else { return }
        try? FileManager.default.removeItem(at: resolved.directory)
    }

    /// 兜底清理：删除**上一个进程**遗留的沙盒目录。
    ///
    /// `kill -9` / 崩溃不会走 `applicationWillTerminate`，隔离目录会残留。
    /// 启动时扫一遍临时区，删掉「不是本进程且已经没人用」的旧目录。
    ///
    /// 安全性：只删临时区里以 `gale-selftest-` 为前缀的目录，绝不碰真实目录；
    /// 用 mtime 过滤掉「刚创建、可能正被另一个自检进程使用」的目录。
    public static func sweepStaleDirectories(olderThan seconds: TimeInterval = 600,
                                             now: Date = Date(),
                                             fileManager: FileManager = .default) {
        let tmp = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = now.addingTimeInterval(-seconds)
        for entry in entries where entry.lastPathComponent.hasPrefix("gale-selftest-") {
            guard let attrs = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = attrs.contentModificationDate,
                  modified < cutoff
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}
