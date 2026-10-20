import AppKit
import Foundation

/// 菜单与 ⌘Q 路由自检。
///
/// 用途：验证「⌘Q 退出无效」这类问题——菜单里到底有没有 Quit 项、
/// 键位是否被别人占用、合成一次 ⌘Q 事件能否真正走到 terminate。
///
/// 用法：GalePlayer --menu-test
/// 说明：会真的尝试退出。若退出成功，进程直接结束；Shell 侧可用退出码判断
/// （配合 `GALE_QUIT_MARKER` 环境变量，AppDelegate 会在 willTerminate 时写标记文件）。
enum MenuTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--menu-test")
    }

    @MainActor
    static func run() {
        var lines: [String] = ["菜单与 ⌘Q 路由自检"]

        guard let menu = NSApp.mainMenu else {
            emit((lines + ["  失败：NSApp.mainMenu 为 nil"]).joined(separator: "\n"))
            exit(70)
        }

        lines.append("  主菜单 \(menu.numberOfItems) 个顶级项：")
        var quitFound = false
        var cmdQOwner: String?
        for index in 0..<menu.numberOfItems {
            guard let top = menu.item(at: index) else { continue }
            lines.append("    · \(top.title.isEmpty ? "(空标题)" : top.title)")
            walk(top, depth: 1, into: &lines, quitFound: &quitFound, cmdQOwner: &cmdQOwner, path: top.title)
        }

        lines.append(quitFound ? "  找到 Quit 菜单项 ✓" : "  未找到 Quit 菜单项 ✗（⌘Q 无处可去）")
        lines.append(cmdQOwner.map { "  ⌘Q 当前绑定者：\($0)" } ?? "  ⌘Q 未被任何菜单项占用")

        report(lines.joined(separator: "\n"))

        // 合成一次 ⌘Q，走 AppKit 真实事件路由
        guard let window = NSApp.windows.first else {
            report("  失败：没有窗口，无法合成按键")
            exit(71)
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: 14   // Q
        ) else {
            report("  失败：无法合成 ⌘Q 事件")
            exit(72)
        }

        NSApp.activate(ignoringOtherApps: true)
        report("  已合成 ⌘Q 并送入 NSApp.sendEvent（若成功退出，进程将在此结束）")
        NSApp.sendEvent(event)

        // 给事件循环 3 秒机会；能走到 terminate 就会结束进程，走不到就报告
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        report("  ✗ 3 秒后仍在运行：合成 ⌘Q 没有触发退出")
        exit(73)
    }

    private static func walk(
        _ item: NSMenuItem,
        depth: Int,
        into lines: inout [String],
        quitFound: inout Bool,
        cmdQOwner: inout String?,
        path: String
    ) {
        guard depth <= 2 else { return }
        let title = item.title.isEmpty ? "(分隔线)" : item.title
        let modifierText = item.keyEquivalentModifierMask.isEmpty
            ? ""
            : "  ⌨\(describe(item.keyEquivalentModifierMask))+\(item.keyEquivalent)"
        lines.append("      " + String(repeating: "  ", count: depth - 1) + "· \(title)\(modifierText)")

        if item.keyEquivalent.lowercased() == "q", item.keyEquivalentModifierMask.contains(.command) {
            cmdQOwner = (path.isEmpty ? title : "\(path) → \(title)")
        }
        if item.action == #selector(NSApplication.terminate(_:)) || item.title.lowercased().contains("quit")
            || title.contains("退出") && item.action == #selector(NSApplication.terminate(_:)) {
            quitFound = true
        }
        if item.action == #selector(NSApplication.terminate(_:)) { quitFound = true }

        if let submenu = item.submenu {
            for index in 0..<submenu.numberOfItems {
                guard let child = submenu.item(at: index) else { continue }
                walk(child, depth: depth + 1, into: &lines, quitFound: &quitFound,
                     cmdQOwner: &cmdQOwner, path: path.isEmpty ? title : "\(path) → \(title)")
            }
        }
    }

    private static func describe(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.shift) { parts.append("⇧") }
        return parts.joined()
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }

    private static func emit(_ text: String) -> Never {
        report(text)
        exit(1)
    }
}