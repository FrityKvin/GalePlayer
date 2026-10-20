import Foundation
import GaleCore

/// 快捷键绑定自检：打印当前生效的键位表（含用户覆盖）。
///
/// 用途：验证「改绑 → 持久化 → 重新读取」链路，以及排查菜单快捷键不生效的问题。
///
/// 用法：GalePlayer --hotkeys
enum HotKeyReport {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--hotkeys")
    }

    static func run() -> Never {
        let store = HotKeyStore()
        var lines = ["当前生效的快捷键（共 \(HotKeyAction.allCases.count) 项）"]
        for category in HotKeyAction.Category.allCases {
            lines.append("[\(category.rawValue)]")
            for action in HotKeyAction.allCases where action.category == category {
                let combo = store.combo(for: action)
                let mark = store.isCustomized(action) ? "  (已改)" : ""
                lines.append("  \(action.title.padding(toLength: 18, withPad: " ", startingAt: 0)) \(combo?.displayString ?? "未设置")\(mark)")
            }
        }
        lines.append("覆盖项存储键：gale.hotkeys.overrides（UserDefaults）")
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        exit(0)
    }
}
