import AppKit
import SwiftUI
import GaleCore

// MARK: - KeyCombo → SwiftUI

extension KeyCombo {
    var keyEquivalent: KeyEquivalent {
        guard let character = key.first else { return KeyEquivalent(" ") }
        return KeyEquivalent(character)
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }
}

extension View {
    /// 有绑定时挂上快捷键，未绑定时原样返回（SwiftUI 不支持可选的 keyboardShortcut）。
    ///
    /// 只给**AppKit 菜单能真正注册**的键挂 `.keyboardShortcut`：实测方向键、
    /// 空格、回车、功能键这类组合挂上去后 `NSMenuItem.keyEquivalent` 是空字符串
    /// （只有修饰键），等于在菜单里塞了一堆畸形项 —— 它们本来也不生效，
    /// 现在统一由 `HotKeyMonitor` 接管，菜单这边就不挂了。
    @ViewBuilder
    func applying(_ combo: KeyCombo?) -> some View {
        if let combo, combo.isUsable, combo.isMenuRegistrable {
            self.keyboardShortcut(combo.keyEquivalent, modifiers: combo.eventModifiers)
        } else {
            self
        }
    }
}

// MARK: - 快捷键录制控件

/// 点击后进入录制态，按下组合键即完成绑定；Esc 取消。
final class ShortcutButton: NSButton {
    var onCapture: ((KeyCombo?) -> Void)?

    private(set) var isRecording = false

    var combo: KeyCombo? {
        didSet { refreshTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 128, height: 22)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if isRecording {
            stopRecording()
        } else {
            isRecording = true
            window.makeFirstResponder(self)
            refreshTitle()
        }
    }

    override var acceptsFirstResponder: Bool { isRecording }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Esc 取消录制
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let modifiers = event.modifierFlags
        if let captured = KeyCombo.from(
            characters: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            isCommand: modifiers.contains(.command),
            isShift: modifiers.contains(.shift),
            isOption: modifiers.contains(.option),
            isControl: modifiers.contains(.control)
        ) {
            combo = captured
            onCapture?(captured)
            stopRecording()
        }
    }

    /// 录制态要吞掉快捷键，避免触发菜单项。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    private func stopRecording() {
        isRecording = false
        refreshTitle()
    }

    private func refreshTitle() {
        if isRecording {
            title = "请按新快捷键…"
            contentTintColor = .controlAccentColor
        } else {
            title = combo?.displayString ?? "未设置"
            contentTintColor = combo == nil ? .secondaryLabelColor : nil
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    let onCapture: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton(frame: NSRect(x: 0, y: 0, width: 128, height: 22))
        button.combo = combo
        button.onCapture = onCapture
        return button
    }

    func updateNSView(_ nsView: ShortcutButton, context: Context) {
        if !nsView.isRecording {
            nsView.combo = combo
        }
        nsView.onCapture = onCapture
    }
}
