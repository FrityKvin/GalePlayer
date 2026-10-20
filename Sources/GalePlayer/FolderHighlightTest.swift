import AppKit
import Foundation
import GaleCore

/// 复现「拖入文件夹 → 点列表 → 点下一个 → 看高亮」的**完整真实路径**自检。
///
/// 与 `HighlightTest` 的区别：那个直接调 `core.play(node:in:)`，
/// 这个走**用户真实会触发的那条**——先 addFolder 产生 toggle，
/// 再对**顶层 toggle** 执行列表的 primaryAction，
/// 最后调 playNext，逐步检查 UI 会渲染的那一行是否高亮。
///
/// 用法：GalePlayer --folder-highlight-test <目录>
enum FolderHighlightTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--folder-highlight-test")
    }

    nonisolated(unsafe) private static var snapshot: [PlaylistNode] = []

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
        var lines: [String] = ["文件夹高亮 · 真实路径自检"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--folder-highlight-test"), args.count > index + 1 else {
            report("用法: --folder-highlight-test <目录>")
            NSApp.terminate(nil)
            return
        }
        let folder = URL(fileURLWithPath: args[index + 1])

        // 用户路径 1：拖入文件夹 → addFolder → 顶层出现一个 toggle
        onMain { settings.clearPlaylist() }
        onMain { settings.addFolder(folder) }

        let topLevel = onMain { settings.playlistItems }
        snapshot = topLevel
        let ordered = onMain { settings.orderedMedia }
        lines.append("  顶层项=\(topLevel.count)（应为 1 个文件夹 toggle）")
        lines.append("  orderedMedia=\(ordered.count)：\(ordered.map(\.name).joined(separator: " → "))")
        if topLevel.count > 1 {
            lines.append("  ⚠️ 顶层有 \(topLevel.count) 项（可能存在重复的文件夹 toggle）")
        }
        guard topLevel.count == 1, topLevel[0].resolvedIsFolder else {
            report((lines + ["  ✗ 顶层结构不是「单个文件夹 toggle」，与拖入文件夹的行为不符"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }

        // 用户路径 2：在列表里点这个 toggle（SidebarPanel 的 primaryAction 原样逻辑）
        let toggle = topLevel[0]
        let startAt = ordered.firstIndex(of: toggle) ?? 0
        lines.append("")
        lines.append("  —— 点列表里的 toggle（primaryAction 原样）——")
        lines.append("  firstIndex(of: toggle) in orderedMedia = \(ordered.firstIndex(of: toggle).map(String.init) ?? "nil")")
        lines.append("  → play(node:in:) 实际 startAt=" + String(startAt))
        onMain { core.play(node: toggle, in: ordered) }
        waitUntilLoaded(core: core)

        guard let first = onMain({ core.currentURL }) else {
            report((lines + ["  ✗ currentURL 为 nil"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        lines.append("  播放后 currentURL=\(first.lastPathComponent)")
        lines.append("  高亮行数=\(countMatches(current: first))（应为 1）")
        let firstHits = countMatches(current: first)

        // 用户路径 3：连点「下一个」，每次都应恰好 1 行高亮且随播放项移动
        lines.append("")
        lines.append("  —— 连点「下一个」——")
        var followOK = true
        var previousName = first.lastPathComponent
        for step in 1...max(1, min(4, ordered.count)) {
            onMain { core.playNext() }
            Thread.sleep(forTimeInterval: 0.8)
            snapshot = onMain { settings.playlistItems }
            guard let url = onMain({ core.currentURL }) else {
                lines.append("    第\(step)次：currentURL=nil ✗")
                followOK = false
                break
            }
            let hit = countMatches(current: url)
            previousName = url.lastPathComponent
            let mark = hit == 1 ? "✓" : "✗"
            let atEnd = step >= ordered.count - 1
            let note = atEnd ? "（已到列表末尾）" : ""
            lines.append("    第\(step)次 → \(url.lastPathComponent)  高亮行数=\(hit) \(mark)\(note)")
            // 真正的判据：**每一帧恰好 1 行高亮**，且高亮的那行就是当前播放的文件。
            // （是否「移动了」不是判据 —— 到末尾时不动是正确行为）
            if hit != 1 { followOK = false }
        }

        let ok = firstHits == 1 && followOK
        lines.append("")
        lines.append("  结论：真实路径高亮" + (ok ? "正常 ✓" : "有缺陷 ✗（firstHits=" + String(firstHits) + " followOK=" + String(followOK) + "）"))
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    private static func waitUntilLoaded(core: PlayerCore) {
        let deadline = Date().addingTimeInterval(20)
        while onMain({ core.duration }) <= 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// 与 SidebarPanel 递归渲染一致
    private static func countMatches(current: URL) -> Int {
        func count(_ nodes: [PlaylistNode]) -> Int {
            nodes.reduce(0) { total, node in
                if node.resolvedIsFolder { return total + count(node.children ?? []) }
                return total + (highlightMatch(current: current, node: node) ? 1 : 0)
            }
        }
        return count(snapshot)
    }

    private static func highlightMatch(current: URL, node: PlaylistNode) -> Bool {
        guard !node.resolvedIsFolder else { return false }
        return current.resolvingSymlinksInPath().standardizedFileURL.path
            == node.url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}