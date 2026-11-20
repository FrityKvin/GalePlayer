import XCTest
@testable import GaleCore

/// 自检数据隔离：自检模式必须用一次性沙盒目录，绝不能碰用户的真实数据。
///
/// 事故背景（2026-11-20）：`--missing-file-test` / `--folder-resync-test` 等自检
/// 内部调用了 `settings.clearPlaylist()`，而 AppSettings 指向**真实**的
/// `~/Library/Application Support/com.kevin.galeplayer/` —— 跑一次自检就把
/// Kevin 的真实播放列表清空了。
///
/// 修复原则：数据目录按运行模式分流（`DataPaths`），自检进程拿到的是临时目录，
/// 进程退出后自动清理；真实模式才用 Application Support。
final class DataPathsTests: XCTestCase {

    /// 自检模式 → 临时沙盒目录（不可等于真实目录）。
    func testSelfTestModeUsesSandboxNotRealDirectory() {
        let paths = DataPaths.resolve(arguments: ["GalePlayer", "--missing-file-test", "a", "b"])
        XCTAssertTrue(paths.isIsolated, "带自检参数时必须走隔离目录")
        XCTAssertTrue(paths.directory.path.contains(FileManager.default.temporaryDirectory.path)
                      || paths.directory.path.contains("/tmp/"),
                      "隔离目录必须在临时区，实际：\(paths.directory.path)")
        XCTAssertNotEqual(paths.directory.lastPathComponent, "com.kevin.galeplayer",
                          "自检绝不能落在真实 bundle-id 目录上")
    }

    /// 普通启动 → 真实目录。
    func testNormalLaunchUsesRealDirectory() {
        let paths = DataPaths.resolve(arguments: ["GalePlayer", "/Users/x/movie.mp4"])
        XCTAssertFalse(paths.isIsolated, "普通启动（含双击文件打开）不得隔离")
        XCTAssertEqual(paths.directory.lastPathComponent, "com.kevin.galeplayer")
    }

    /// 无参数启动（双击 App）也是真实目录。
    func testNoArgumentsUsesRealDirectory() {
        let paths = DataPaths.resolve(arguments: ["GalePlayer"])
        XCTAssertFalse(paths.isIsolated)
        XCTAssertEqual(paths.directory.lastPathComponent, "com.kevin.galeplayer")
    }

    /// 覆盖全部已知自检 flag：每一个都必须触发隔离。
    func testEveryKnownSelfTestFlagIsIsolated() {
        let flags = [
            "--diagnose", "--hotkeys", "--list-folder", "--lifecycle-test",
            "--update-check", "--perf-test", "--window-report", "--menu-test",
            "--input-test", "--mouse-test", "--ui-rebuild-test", "--resume-test",
            "--highlight-test", "--folder-highlight-test",
            "--playlist-export-test", "--scroll-conflict-test",
            "--missing-file-test", "--folder-resync-test",
            "--transform-test", "--hit-test-report", "--resource-test",
        ]
        for flag in flags {
            let paths = DataPaths.resolve(arguments: ["GalePlayer", flag])
            XCTAssertTrue(paths.isIsolated, "\(flag) 必须走隔离目录，否则会污染真实数据")
        }
    }

    /// 隔离目录必须是**进程唯一**的：两个同时跑的自检不能互相踩数据。
    func testIsolatedDirectoryIsUniquePerProcess() {
        let a = DataPaths.resolve(arguments: ["GalePlayer", "--missing-file-test", "x", "y"])
        let b = DataPaths.resolve(arguments: ["GalePlayer", "--missing-file-test", "x", "y"])
        XCTAssertNotEqual(a.directory.path, b.directory.path,
                          "两个自检进程必须各用各的目录（否则并发自检互相覆盖）")
    }

    /// 显式环境变量覆盖（移植/调试用）：GALE_DATA_DIR 必须被尊重且视为隔离。
    func testEnvOverrideIsHonored() {
        let dir = "/tmp/explicit-gale-dir"
        let paths = DataPaths.resolve(arguments: ["GalePlayer"], environment: ["GALE_DATA_DIR": dir])
        XCTAssertTrue(paths.isIsolated, "显式指定数据目录时按隔离处理（不写真实目录）")
        XCTAssertEqual(paths.directory.path.hasSuffix(dir) || paths.directory.path.contains("explicit-gale-dir"), true)
    }

    /// 真实目录判定不得被「看起来像 flag」的普通文件名误导。
    func testFileNameThatLooksLikeFlagDoesNotIsolate() {
        // 用户双击了一个名叫 "--mouse-test.mp4" 的文件
        let paths = DataPaths.resolve(arguments: ["GalePlayer", "/Users/kevin/Movies/--mouse-test.mp4"])
        XCTAssertFalse(paths.isIsolated, "文件名里带 flag 字样不得误判为自检模式")
    }

    /// 兜底清理：只删「旧的」沙盒目录，不删刚创建的（可能正被并发自检使用）。
    func testSweepRemovesOnlyStaleDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory
        let stale = tmp.appendingPathComponent("gale-selftest-STALE-TEST", isDirectory: true)
        let fresh = tmp.appendingPathComponent("gale-selftest-FRESH-TEST", isDirectory: true)
        let unrelated = tmp.appendingPathComponent("not-a-gale-dir-TEST", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fresh)
            try? FileManager.default.removeItem(at: unrelated)
        }

        // 把 stale 的 mtime 改成 1 小时前
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

        DataPaths.sweepStaleDirectories(olderThan: 600, now: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "超过阈值的旧沙盒目录必须被清掉")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "刚创建的目录不得被删（可能正被另一个自检进程使用）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),
                      "非 gale-selftest 前缀的目录绝不能碰")
    }
}
