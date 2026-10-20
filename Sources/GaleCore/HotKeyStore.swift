import Combine
import Foundation

/// 快捷键绑定表：默认值 + 用户覆盖，持久化到 UserDefaults。
///
/// 存储约定：只保存「与默认不同」的项。`KeyCombo(key: "")` 表示用户显式取消了绑定，
/// 因此清空与未设置是两种状态。
public final class HotKeyStore: ObservableObject {
    @Published public private(set) var overrides: [String: KeyCombo] = [:]

    private let defaults: UserDefaults
    private static let storageKey = "gale.hotkeys.overrides"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - 读取

    public func combo(for action: HotKeyAction) -> KeyCombo? {
        if let override = overrides[action.rawValue] {
            return override.isCleared ? nil : override
        }
        let fallback = action.defaultCombo
        return fallback.isCleared ? nil : fallback
    }

    public func isCustomized(_ action: HotKeyAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// 与某个组合冲突的操作（用于设置界面提示）。
    public func conflictingAction(for target: KeyCombo, excluding action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { candidate in
            candidate != action && combo(for: candidate) == target
        }
    }

    // MARK: - 写入

    public func set(_ combo: KeyCombo?, for action: HotKeyAction) {
        if let combo {
            overrides[action.rawValue] = combo
        } else {
            overrides[action.rawValue] = KeyCombo(key: "")
        }
        persist()
    }

    public func reset(_ action: HotKeyAction) {
        overrides.removeValue(forKey: action.rawValue)
        persist()
    }

    public func resetAll() {
        overrides.removeAll()
        persist()
    }

    /// 供设置页与自检输出的一览表。
    public func table() -> [(action: HotKeyAction, combo: KeyCombo?, customized: Bool)] {
        HotKeyAction.allCases.map { action in
            (action, combo(for: action), isCustomized(action))
        }
    }

    // MARK: - 磁盘

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else {
            return
        }
        overrides = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
