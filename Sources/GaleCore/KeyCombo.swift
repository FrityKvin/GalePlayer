import Foundation

/// 一个按键组合。
///
/// `key` 恒为一个字符：普通按键存该字符本身（字母小写）；特殊键存 macOS 的
/// 私有区码位（↑ = U+0xF700、F5 = U+0xF708 等），显示时再映射成符号。
public struct KeyCombo: Codable, Hashable, Sendable {
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// 空 key 表示「已取消绑定」。
    public var isCleared: Bool { key.isEmpty }
    public var isUsable: Bool { key.count == 1 }

    /// 是否含有修饰键（用于判断录制到的按键是否有效）。
    public var hasModifier: Bool { command || shift || option || control }

    /// 是否能被 AppKit 菜单注册为键位。
    ///
    /// 只有单字符且位于可见区（标量 < U+F700）的键才行；箭头/空格/回车/功能键
    /// 存的是私有区码位，挂到菜单上会得到空的 `keyEquivalent`，属于无效项。
    public var isMenuRegistrable: Bool {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        return scalar.value < 0xF700
    }

    public var displayString: String {
        guard !isCleared else { return "未设置" }
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + Self.symbol(for: key)
    }

    /// 私有区码位 → 可读符号。
    public static func symbol(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return key }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF70F: return "F\(scalar.value - 0xF703)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x20: return "空格"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x7F: return "⌫"
        default: return key.uppercased()
        }
    }

    /// 私有区码位常量，供录制时使用。
    public enum SpecialKey {
        public static let up = "\u{F700}"
        public static let down = "\u{F701}"
        public static let left = "\u{F702}"
        public static let right = "\u{F703}"
        public static func function(_ n: Int) -> String {
            guard (1...12).contains(n), let scalar = UnicodeScalar(UInt32(0xF703 + n)) else { return "" }
            return String(Character(scalar))
        }
        public static let space = " "
        public static let ret = "\r"
        public static let tab = "\t"
        public static let escape = "\u{1B}"
        public static let delete = "\u{7F}"
        /// 录制时用来识别「只按了修饰键」等无效输入
        public static let modifierKeyCodes: Set<UInt16> = [55, 54, 56, 57, 58, 59, 60, 61, 62, 63]
    }

    /// 从 NSEvent 的原始字段构造（AppKit 侧只做取值，判断逻辑留在这里便于单测）。
    ///
    /// `characters` 对特殊键经常是空的（合成事件尤其如此），因此以 **keyCode 为兜底**：
    /// 拿不到可用字符时按硬件键码映射到私有区码位，和录制器共用同一套判定。
    public static func from(
        characters: String?,
        keyCode: UInt16,
        isCommand: Bool,
        isShift: Bool,
        isOption: Bool,
        isControl: Bool
    ) -> KeyCombo? {
        guard !SpecialKey.modifierKeyCodes.contains(keyCode) else { return nil }

        var key: String?
        if let first = characters?.first {
            let scalar = scalarOf(first)
            if scalar >= 0xF700 {
                key = String(first)                       // 已经是私有区码位（箭头/功能键）
            } else if scalar >= 0x20 {
                key = String(first).lowercased()          // 可打印字符与空格
            }
        }
        if key == nil {
            key = specialKey(forKeyCode: keyCode)        // 兜底：按硬件键码判定
        }
        guard let key, !key.isEmpty else { return nil }

        return KeyCombo(
            key: key,
            command: isCommand,
            shift: isShift,
            option: isOption,
            control: isControl
        )
    }

    /// 硬件键码 → 私有区码位（macOS 标准虚拟键码）。
    ///
    /// 存在的理由：方向键/功能键/回车这类键在 `NSEvent.characters` 里经常缺失或为空，
    /// 只靠 characters 会漏判；keyCode 永远是可靠的。
    public static func specialKey(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 123: return SpecialKey.left
        case 124: return SpecialKey.right
        case 125: return SpecialKey.down
        case 126: return SpecialKey.up
        case 49: return SpecialKey.space
        case 36, 76: return SpecialKey.ret
        case 53: return SpecialKey.escape
        case 48: return SpecialKey.tab
        case 51, 116: return SpecialKey.delete
        case 122: return SpecialKey.function(1)
        case 120: return SpecialKey.function(2)
        case 99: return SpecialKey.function(3)
        case 118: return SpecialKey.function(4)
        case 96: return SpecialKey.function(5)
        case 97: return SpecialKey.function(6)
        case 98: return SpecialKey.function(7)
        case 100: return SpecialKey.function(8)
        case 101: return SpecialKey.function(9)
        case 109: return SpecialKey.function(10)
        case 103: return SpecialKey.function(11)
        case 111: return SpecialKey.function(12)
        default: return nil
        }
    }

    private static func scalarOf(_ character: Character) -> UInt32 {
        character.unicodeScalars.first?.value ?? 0
    }
}
