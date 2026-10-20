import XCTest
@testable import GaleCore

/// 快捷键模型与绑定表测试。
final class HotKeyTests: XCTestCase {

    // MARK: - 默认键位（须与两处证据一致）

    func testPlaybackDefaults() {
        XCTAssertEqual(HotKeyAction.playPause.defaultCombo.displayString, "空格")
        XCTAssertEqual(HotKeyAction.stop.defaultCombo.displayString, "⌘S")
        XCTAssertEqual(HotKeyAction.seekBackward.defaultCombo.displayString, "←")
        XCTAssertEqual(HotKeyAction.seekForward.defaultCombo.displayString, "→")
        XCTAssertEqual(HotKeyAction.previousMedia.defaultCombo.displayString, "⌘↑")
        XCTAssertEqual(HotKeyAction.nextMedia.defaultCombo.displayString, "⌘↓")
        XCTAssertEqual(HotKeyAction.volumeUp.defaultCombo.displayString, "↑")
        XCTAssertEqual(HotKeyAction.volumeDown.defaultCombo.displayString, "↓")
        XCTAssertEqual(HotKeyAction.mute.defaultCombo.displayString, "⌘M")
        XCTAssertEqual(HotKeyAction.fullScreen.defaultCombo.displayString, "↩")
        XCTAssertEqual(HotKeyAction.screenshot.defaultCombo.displayString, "⇧F5")
        XCTAssertEqual(HotKeyAction.alwaysOnTop.defaultCombo.displayString, "⌘T")
        XCTAssertEqual(HotKeyAction.openFile.defaultCombo.displayString, "⌘O")
        XCTAssertEqual(HotKeyAction.openFolder.defaultCombo.displayString, "⌘F")
    }

    func testChapterDefaults() {
        XCTAssertEqual(HotKeyAction.chapterAdd.defaultCombo.displayString, "⌘A")
        XCTAssertEqual(HotKeyAction.chapterDelete.defaultCombo.displayString, "⌘D")
        XCTAssertEqual(HotKeyAction.chapterNext.defaultCombo.displayString, "⌘N")
        XCTAssertEqual(HotKeyAction.chapterPrevious.defaultCombo.displayString, "⌘P")
    }

    /// 默认键位之间不能互相冲突，否则菜单里会有两个相同快捷键。
    func testDefaultCombosAreUnique() {
        var seen: [KeyCombo: HotKeyAction] = [:]
        for action in HotKeyAction.allCases {
            let combo = action.defaultCombo
            if let existing = seen[combo] {
                XCTFail("默认快捷键冲突：\(action.title) 与 \(existing.title) 都是 \(combo.displayString)")
            }
            seen[combo] = action
        }
    }

    func testEveryActionHasATitleAndCategory() {
        for action in HotKeyAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.category.rawValue.isEmpty)
        }
    }

    // MARK: - 显示与解析

    func testSpecialKeySymbols() {
        XCTAssertEqual(KeyCombo(key: KeyCombo.SpecialKey.up).displayString, "↑")
        XCTAssertEqual(KeyCombo(key: KeyCombo.SpecialKey.function(5), shift: true).displayString, "⇧F5")
        XCTAssertEqual(KeyCombo(key: KeyCombo.SpecialKey.function(12)).displayString, "F12")
        XCTAssertEqual(KeyCombo(key: "a", command: true, shift: true).displayString, "⇧⌘A")
        XCTAssertEqual(KeyCombo(key: "").displayString, "未设置")
    }

    func testFromEventRejectsModifierOnlyPresses() {
        // keyCode 55 = 左 Command
        XCTAssertNil(KeyCombo.from(
            characters: nil, keyCode: 55,
            isCommand: true, isShift: false, isOption: false, isControl: false
        ))
        // 无字符输入（例如单独按 Shift）
        XCTAssertNil(KeyCombo.from(
            characters: "", keyCode: 56,
            isCommand: false, isShift: true, isOption: false, isControl: false
        ))
    }

    func testFromEventNormalisesLettersAndKeepsSpecialKeys() {
        let plain = KeyCombo.from(
            characters: "A", keyCode: 0,
            isCommand: true, isShift: false, isOption: false, isControl: false
        )
        XCTAssertEqual(plain?.key, "a", "字母统一存小写")
        XCTAssertEqual(plain?.displayString, "⌘A")

        let arrow = KeyCombo.from(
            characters: KeyCombo.SpecialKey.left, keyCode: 123,
            isCommand: false, isShift: false, isOption: false, isControl: false
        )
        XCTAssertEqual(arrow?.displayString, "←", "方向键保持私有区码位并正确显示")

        let f5 = KeyCombo.from(
            characters: KeyCombo.SpecialKey.function(5), keyCode: 96,
            isCommand: false, isShift: true, isOption: false, isControl: false
        )
        XCTAssertEqual(f5?.displayString, "⇧F5")
    }

    // MARK: - 绑定表

    private func makeStore() -> HotKeyStore {
        let suite = "gale.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HotKeyStore(defaults: defaults)
    }

    func testOverrideAndPersistence() {
        let suite = "gale.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = HotKeyStore(defaults: defaults)
        XCTAssertEqual(store.combo(for: .screenshot)?.displayString, "⇧F5")
        XCTAssertFalse(store.isCustomized(.screenshot))

        store.set(KeyCombo(key: "k", command: true, shift: true), for: .screenshot)
        XCTAssertEqual(store.combo(for: .screenshot)?.displayString, "⇧⌘K")
        XCTAssertTrue(store.isCustomized(.screenshot))

        // 新实例应读回同一份覆盖
        let reopened = HotKeyStore(defaults: defaults)
        XCTAssertEqual(reopened.combo(for: .screenshot)?.displayString, "⇧⌘K")
    }

    func testClearingBindingIsDistinctFromDefault() {
        let store = makeStore()
        store.set(nil, for: .mute)
        XCTAssertNil(store.combo(for: .mute), "清除后不应回落到默认")
        XCTAssertTrue(store.isCustomized(.mute))

        store.reset(.mute)
        XCTAssertEqual(store.combo(for: .mute)?.displayString, "⌘M", "恢复默认")
        XCTAssertFalse(store.isCustomized(.mute))
    }

    func testResetAll() {
        let store = makeStore()
        store.set(KeyCombo(key: "1", command: true), for: .playPause)
        store.set(KeyCombo(key: "2", command: true), for: .stop)
        XCTAssertTrue(store.isCustomized(.playPause))

        store.resetAll()
        XCTAssertFalse(store.isCustomized(.playPause))
        XCTAssertFalse(store.isCustomized(.stop))
        XCTAssertEqual(store.combo(for: .playPause)?.displayString, "空格")
    }

    func testConflictDetection() {
        let store = makeStore()
        // 把「静音」改成和「截图」相同的键
        store.set(store.combo(for: .screenshot), for: .mute)
        let conflict = store.conflictingAction(for: KeyCombo(key: KeyCombo.SpecialKey.function(5), shift: true), excluding: .mute)
        XCTAssertEqual(conflict, .screenshot)

        let none = store.conflictingAction(for: KeyCombo(key: "9", command: true, option: true), excluding: .mute)
        XCTAssertNil(none)
    }

    func testTableCoversEveryAction() {
        let store = makeStore()
        XCTAssertEqual(store.table().count, HotKeyAction.allCases.count)
        XCTAssertTrue(store.table().allSatisfy { $0.combo != nil }, "默认状态下每个操作都应有键位")
    }
}
