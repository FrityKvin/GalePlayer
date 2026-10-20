import AppKit
import SwiftUI
import GaleCore

/// 全局按键接管。
///
/// 为什么需要它：**SwiftUI 菜单只对字母键真正注册键位**。实测菜单里
/// `快退 60 秒 ⇧←`、`上一个视频 ⌘↑`、`全屏 ↩`、`截图 ⇧F5` 的
/// `NSMenuItem.keyEquivalent` 全是空字符串（只有修饰键），也就是说这些快捷键
/// 根本不会触发 —— 因为全工程没有任何 `keyDown` 处理兜底。
/// 字母键（⌘S/⌘M/⌘T…）菜单能生效，所以从用户视角是「一半快捷键是死的」。
///
/// 因此改为：菜单继续挂 `.keyboardShortcut`（可发现性 + 字母键走系统路径），
/// 同时装一个本地事件监视器兜住所有按键（含箭头/空格/功能键）。
///
/// 不会重复触发：菜单键位在 `NSApplication.sendEvent` 阶段就被消费掉了，
/// 事件根本不会走到窗口，监视器也就看不到它。
///
/// 显式放过 ⌘Q：退出必须始终由系统菜单处理，任何情况下都不吞。
@MainActor
final class HotKeyMonitor {
    private static var shared: HotKeyMonitor?

    private var token: Any?
    private weak var core: PlayerCore?
    private weak var hotKeys: HotKeyStore?

    /// 安装（幂等）。需在主线程调用。
    static func install(core: PlayerCore, hotKeys: HotKeyStore) {
        guard shared == nil else { return }
        let monitor = HotKeyMonitor()
        monitor.core = core
        monitor.hotKeys = hotKeys
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 注意：NSEvent 不是 Sendable，不能直接带进 @MainActor 闭包，
            // 因此先把需要的纯值取出来再跨隔离。
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                monitor.consume(characters: characters, keyCode: keyCode, flags: flags)
            }
            return consumed ? nil : event   // nil = 吃掉
        }
        shared = monitor
    }

    /// 自检用：当前是否已安装。
    static var isInstalled: Bool { shared != nil }

    /// 自检用：最近一次解析出的按键、命中的动作（没命中则为空）。
    nonisolated(unsafe) static var debugLastParsed: String = "（无）"
    nonisolated(unsafe) static var debugLastMatched: String = "（无）"
    nonisolated(unsafe) static var debugEventCount = 0

    /// 返回 true 表示已消费该按键。
    private func consume(characters: String?, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        // 正在输入文字时不管（否则打字会被快捷键吃掉）
        if isTextInputFocused() { return false }

        // 系统保留组合：⌘Q 交给菜单（退出必须永远由系统处理），⌘W/⌘Space/⌘` 一律不碰
        if flags.contains(.command) {
            let key = characters?.lowercased() ?? ""
            if key == "q" || key == " " || key == "w" || key == "`" { return false }
        }

        guard let hotKeys,
              let combo = KeyCombo.from(
                characters: characters,
                keyCode: keyCode,
                isCommand: flags.contains(.command),
                isShift: flags.contains(.shift),
                isOption: flags.contains(.option),
                isControl: flags.contains(.control)
              ) else { return false }

        Self.debugEventCount += 1
        Self.debugLastParsed = "\(combo.displayString) (key=\(combo.key.unicodeScalars.first.map { String(format: "U+%04X", $0.value) } ?? "?"))"
        guard let match = hotKeys.table().first(where: { $0.combo == combo && combo.isUsable }) else {
            Self.debugLastMatched = "（无匹配）"
            return false
        }
        Self.debugLastMatched = match.action.rawValue
        core?.perform(match.action)
        return true
    }

    /// 当前第一响应者是否是文本输入（设置页输入框）。
    private func isTextInputFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }
}