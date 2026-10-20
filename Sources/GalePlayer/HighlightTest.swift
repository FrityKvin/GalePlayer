import AppKit
import Foundation
import GaleCore

/// 播放列表「高亮正在播放项」自检：真跑一遍高亮判定逻辑。
///
/// 用法：GalePlayer --highlight-test <媒体文件> [更多文件...]
///
/// 要回答的问题：`core.currentURL` 与播放列表节点的 URL 到底能不能对上。
/// 上层样式（▶ 标记 / 粗体 / 底色）都依赖这个判定，
/// 判定为 false 就等于「功能没实现」——即使代码里写着高亮。
enum HighlightTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--highlight-test")
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
        var lines: [String] = ["播放列表高亮自检"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--highlight-test"), args.count > index + 1 else {
            report("用法: --highlight-test <媒体文件>... | --highlight-test --folder <目录>")
            NSApp.terminate(nil)
            return
        }

        // 1) 先清空再加入：否则多轮运行会累积重复项，
        //    按路径匹配的高亮会把所有副本一起点亮，结论失真。
        onMain { settings.clearPlaylist() }

        // 文件夹场景（用户报的正是这一种）：拖入整个文件夹后点「下一个」
        var mode = "扁平列表"
        if args[index + 1] == "--folder", args.count > index + 2 {
            let folder = URL(fileURLWithPath: args[index + 2])
            mode = "文件夹"
            onMain { settings.addFolder(folder) }
            lines.append("  场景=拖入文件夹 \(folder.lastPathComponent)")
        } else {
            let urls = args[(index + 1)...].map { URL(fileURLWithPath: $0) }
            let nodes = Playlist.mediaNodes(from: urls)
            onMain { settings.addNodes(nodes) }
            lines.append("  场景=\(urls.count) 个文件")
        }
        let playlistItems = onMain { settings.playlistItems }
        lines.append("  播放列表项数=\(playlistItems.count) orderedMedia=\(onMain { settings.orderedMedia }.count)")
        for node in playlistItems {
            if node.resolvedIsFolder {
                lines.append("    · \(node.name)（文件夹，含 \(node.flattenedMedia.count) 个媒体）")
            } else {
                lines.append("    · \(node.name)")
            }
        }

        // 2) 队列用 orderedMedia（与列表点击完全一致）
        let ordered = onMain { settings.orderedMedia }
        lines.append("  列表顶层项数=\(playlistItems.count)  orderedMedia=\(ordered.count)")

        let targetIndex = min(1, max(0, ordered.count - 1))
        let target = ordered[targetIndex]
        lines.append("  播放目标=\(target.name)")
        // 走与双击列表项完全相同的路径（play(node:in:) → loadInto → 设置 currentURL）
        onMain { core.play(node: target, in: ordered) }

        // 等加载完成
        let deadline = Date().addingTimeInterval(20)
        while onMain({ core.duration }) <= 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard onMain({ core.duration }) > 0 else {
            report((lines + ["  失败：媒体未加载"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }

        // 3) 关键比对：currentURL 与各节点 URL 是否匹配
        guard let current = onMain({ core.currentURL }) else {
            report((lines + ["  ✗ core.currentURL 为 nil —— 高亮判定必然全部 false，这就是「没实现」的根因"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        lines.append("  core.currentURL=\(current.path)")
        // 路径归一化一致性：currentURL 与列表节点必须归一化到同一个字符串，
        // 否则一个 /tmp、一个 /private/tmp 就永远匹配不上（真实拖入场景高概率踩到）
        lines.append("  归一化后=\(current.resolvingSymlinksInPath().standardizedFileURL.path)")
        if let node = ordered.first(where: { !$0.resolvedIsFolder }) {
            lines.append("  列表节点示例=\(node.url.path)")
            lines.append("  归一化后  =\(node.url.resolvingSymlinksInPath().standardizedFileURL.path)")
            lines.append("  两者相同=\(current.resolvingSymlinksInPath().standardizedFileURL.path == node.url.resolvingSymlinksInPath().standardizedFileURL.path)")
        }

        settingsSnapshot = playlistItems
        playlistItemsRef = playlistItems
        // 逐行打印（含文件夹子项）——判定必须与 SidebarPanel 的递归渲染一致
        var flatRows: [(String, Bool)] = []
        func collect(_ nodes: [PlaylistNode], depth: Int = 0) {
            for node in nodes {
                if node.resolvedIsFolder {
                    flatRows.append(("\(String(repeating: "  ", count: depth))\(node.name)（文件夹）", false))
                    collect(node.children ?? [], depth: depth + 1)
                } else {
                    flatRows.append(("\(String(repeating: "  ", count: depth))\(node.name)",
                                     highlightMatch(current: current, node: node)))
                }
            }
        }
        collect(playlistItems)
        for (name, matched) in flatRows {
            lines.append("    \(matched ? "✓ 高亮" : "  ·   ")  \(name)")
        }

        let hitCount = flatRows.filter(\.1).count
        lines.append("")
        lines.append("  判定命中 \(hitCount)/\(flatRows.count) 行（应为 1）")

        // 关键回归：点「下一个」之后高亮是否跟着走
        lines.append("")
        lines.append("  —— 依次点「下一个」，看高亮是否跟随 ——")
        var followOK = true
        for step in 0..<min(3, max(0, ordered.count - targetIndex)) {
            onMain { core.playNext() }
            Thread.sleep(forTimeInterval: 0.8)
            guard let url = onMain({ core.currentURL }) else {
                lines.append("    第\(step + 1)次：currentURL 为 nil ✗")
                followOK = false
                continue
            }
            playlistItemsRef = onMain { currentPlaylistItemsRefValue() }
            let hit = countMatches(current: url)
            lines.append("    第\(step + 1)次 → \(url.lastPathComponent)  匹配行数=\(hit)\(hit == 1 ? " ✓" : " ✗")")
            if hit != 1 { followOK = false }
        }
        lines.append("  高亮跟随：\(followOK ? "✓" : "✗")")
        let ok = hitCount == 1 && followOK
        lines.append("  结论：\(mode) 场景 —— \(ok ? "高亮判定正确 ✓" : "高亮判定失败 ✗")")

        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 统计列表里有几行会高亮（必须与 SidebarPanel 的递归渲染一致）。
    private static func countMatches(current: URL) -> Int {
        func count(_ nodes: [PlaylistNode]) -> Int {
            nodes.reduce(0) { total, node in
                if node.resolvedIsFolder {
                    return total + count(node.children ?? [])
                }
                return total + (highlightMatch(current: current, node: node) ? 1 : 0)
            }
        }
        return count(playlistItemsRef)
    }

    private static func currentPlaylistItemsRefValue() -> [PlaylistNode] { settingsSnapshot }

    /// 与 SidebarPanel.isCurrent 完全一致的比对逻辑（改动时必须同步）。
    private static func highlightMatch(current: URL, node: PlaylistNode) -> Bool {
        guard !node.resolvedIsFolder else { return false }
        return current.resolvingSymlinksInPath().standardizedFileURL.path
            == node.url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 自检期间持有的列表快照（countMatches 在主线程外读它）
    nonisolated(unsafe) private static var playlistItemsRef: [PlaylistNode] = []
    nonisolated(unsafe) private static var settingsSnapshot: [PlaylistNode] = []
    private static func currentPlaylistItemsRef() -> [PlaylistNode] { playlistItemsRef }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}