import AppKit
import Foundation
import GaleCore

/// 缺失文件处理自检：文件不存在时播放器必须「标记 + 跳过 + 推进」。
///
/// 用法：GalePlayer --missing-file-test <不存在的媒体路径> <正常媒体>
///
/// 要回答的问题（Kevin 报的真实缺陷）：
///   播放列表里的文件被删除后，点它播放器会卡死——不跳过、不标记、无提示。
/// 修复后的预期行为：
///   1. 缺失项在播放列表里打上红色感叹号（isMissing 判定成立）
///   2. 播到/点到缺失项：不发 loadfile，直接推进到下一个可播项
///   3. Toast 提示「文件不存在，已跳过」
///   4. 全部缺失时不无限循环、不清空列表
enum MissingFileTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--missing-file-test")
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
        var lines: [String] = ["缺失文件处理自检"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--missing-file-test"), args.count > index + 2 else {
            report("用法: --missing-file-test <不存在的媒体> <正常媒体>")
            report("  失败：参数不足")
            NSApp.terminate(nil)
            return
        }
        let missingURL = URL(fileURLWithPath: args[index + 1])
        let okURL = URL(fileURLWithPath: args[index + 2])

        guard !FileManager.default.fileExists(atPath: missingURL.path) else {
            report("  失败：第一个参数必须是**不存在**的路径，实际存在：\(missingURL.path)")
            NSApp.terminate(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: okURL.path) else {
            report("  失败：第二个参数必须是存在的正常媒体：\(okURL.path)")
            NSApp.terminate(nil)
            return
        }
        lines.append("  缺失项=\(missingURL.lastPathComponent)  正常项=\(okURL.lastPathComponent)")

        var failed: [String] = []
        var passedTotal = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passedTotal += 1; lines.append("  ✓ \(label)") } else { failed.append(label); lines.append("  ✗ \(label)") }
        }

        // 1) 清空并重建列表：缺失在前、正常在后
        onMain { settings.clearPlaylist() }
        let nodes = Playlist.mediaNodes(from: [missingURL, okURL])
        onMain { settings.addNodes(nodes) }
        let ordered = onMain { settings.orderedMedia }
        lines.append("  列表项数=\(onMain { settings.orderedMedia }.count)（应为 2）")

        // 2) 全表刷新后缺失标记是否挂上
        onMain { settings.refreshMissingFiles() }
        let missingPaths = onMain { settings.missingMediaPaths }
        check(missingPaths.contains(missingURL.path), "缺失项路径进入 missingMediaPaths（打标记）")
        check(!missingPaths.contains(okURL.path), "正常项不被误标")
        check(missingPaths.count == 1, "缺失集合恰为 1 项（不重复）")

        // 3) 直接点缺失项：必须被拒 + 推进到正常项
        let missingNode = ordered.first { $0.url.path == missingURL.path }!
        let beforeURL = onMain { core.currentURL?.path }
        onMain { core.play(node: missingNode, in: ordered) }

        // 等推进完成（正常文件加载出 duration）。
        // 注意 polling 之间必须 Thread.sleep——后台线程不持有主线程，
        // onMain 是 DispatchQueue.main.sync，主线程若正被 Task{@MainActor}
        // 的 async 调用链占用会形成 dispatch_sync 重入死锁（SIGTRAP 9005674541351168）。
        let deadline = Date().addingTimeInterval(20)
        while onMain({ core.currentURL?.path }) != okURL.path, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        check(onMain({ core.currentURL?.path }) == okURL.path,
              "点缺失项后推进到正常项（而不是卡死在缺失项）")
        check(beforeURL != missingURL.path || onMain({ core.currentURL?.path }) != missingURL.path,
              "缺失项从未成为 currentURL（不发 loadfile）")

        // 等加载成功拿到 duration（证明真的播起来了）
        let deadline2 = Date().addingTimeInterval(20)
        while onMain({ core.duration }) <= 0, Date() < deadline2 {
            Thread.sleep(forTimeInterval: 0.2)
        }
        check(onMain({ core.duration }) > 0, "正常项已加载（duration > 0）")
        check(onMain({ core.currentURL?.path }) != missingURL.path, "卡死症状消失：currentURL 不停留在缺失项")

        // 4) playNext 跨过缺失：正常项播完后 next 应跳过缺失（队列尾部 wrap 或停下都行，
        //    但绝不能把 currentURL 换成缺失项）
        onMain { core.playNext() }
        let deadline3 = Date().addingTimeInterval(8)
        while Date() < deadline3 {
            Thread.sleep(forTimeInterval: 0.2)
            let cur = onMain({ core.currentURL?.path })
            if cur != okURL.path { break }
        }
        check(onMain({ core.currentURL?.path }) != missingURL.path,
              "playNext 不会把播放器推回缺失项")

        // 5) 单缺失列表：只有缺失项时不无限递归推进（app 必须活着）
        onMain { settings.clearPlaylist() }
        let solo = Playlist.mediaNodes(from: [missingURL])
        onMain { settings.addNodes(solo) }
        onMain { settings.refreshMissingFiles() }
        let soloOrdered: [PlaylistNode] = onMain { settings.orderedMedia }
        onMain { core.play(node: solo[0], in: soloOrdered) }
        let deadline4 = Date().addingTimeInterval(5)
        while Date() < deadline4 { Thread.sleep(forTimeInterval: 0.2) }
        check(true, "全部缺失时不无限循环（app 存活即通过，5 秒无挂死）")
        check(onMain({ core.currentURL?.path }) != missingURL.path || onMain({ core.duration }) <= 0,
              "单缺失列表：currentURL 不落在缺失项上")

        // 汇总
        lines.append("")
        if failed.isEmpty {
            lines.append("结果：PASS（\(passedTotal) 项断言全过）")
        } else {
            lines.append("结果：FAIL —— \(failed.count) 项未过：\(failed.joined(separator: "；"))")
        }
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 与 HighlightTest 同款主线程跳板（后台线程驱动 + DispatchQueue.main.sync）。
    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}
