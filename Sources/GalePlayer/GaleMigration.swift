import Foundation

/// 从旧名字（Zephyr）迁移到 Gale Player。
///
/// 改名涉及**两处绑定在旧 bundle id 上的持久化**，只改字符串会让用户数据静默消失：
///
/// 1. 文件：`~/Library/Application Support/com.kevin.zephyr/`
///    （playlist.json / chapters.json / playback-history.json）
/// 2. UserDefaults：`UserDefaults.standard` 的实际落盘域就是 bundle id，
///    改 id 等于换了一个域 —— 设置项与快捷键覆盖都会"凭空重置"。
///
/// 因此必须在**任何**读取（AppSettings / HotKeyStore / Playlist / ChapterStore / PlaybackHistory）
/// 之前调用一次 `runIfNeeded()`。
///
/// 设计选择：
/// - 只**复制**不删除旧目录。用户数据不该由升级流程擅自删除，
///   确认新版一切正常后由用户自己清理（`legacyDirectoryDescription` 会报出路径）。
/// - 幂等：靠「新目录已有的文件不动 + 只填空缺的 UserDefaults 键」保证，
///   重复运行不会覆盖新数据。
enum GaleMigration {

    /// 旧 bundle id（改名前的）
    static let legacyBundleID = "com.kevin.zephyr"
    /// 新 bundle id
    static let currentBundleID = "com.kevin.galeplayer"

    /// 迁移过的标记键（避免每次启动都去读旧域）
    private static let markerKey = "gale.migratedFromZephyr.v1"

    /// 旧目录路径（供提示用户清理 / 自检使用）
    static var legacyDirectoryDescription: String {
        "~/Library/Application Support/\(legacyBundleID)"
    }

    /// 执行迁移（幂等，可在启动时无条件调用）。
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard) -> [String] {
        var report: [String] = []
        let alreadyDone = defaults.bool(forKey: markerKey)

        // ---------- ① 文件 ----------
        let fileResult = migrateFiles()
        if let fileResult { report.append(fileResult) }

        // ---------- ② UserDefaults ----------
        if !alreadyDone {
            let copied = migrateDefaults(defaults: defaults)
            if !copied.isEmpty {
                report.append("UserDefaults 迁移 \(copied.count) 项：\(copied.joined(separator: ", "))")
            }
            defaults.set(true, forKey: markerKey)
        }

        return report
    }

    /// 复制旧数据目录里缺失的文件。返回人类可读的说明（无需迁移时为 nil）。
    private static func migrateFiles() -> String? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let legacyDir = base.appendingPathComponent(legacyBundleID, isDirectory: true)
        let currentDir = base.appendingPathComponent(currentBundleID, isDirectory: true)

        guard fm.fileExists(atPath: legacyDir.path) else { return nil }
        try? fm.createDirectory(at: currentDir, withIntermediateDirectories: true)

        let entries = (try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil)) ?? []
        var copied: [String] = []
        for source in entries {
            let destination = currentDir.appendingPathComponent(source.lastPathComponent)
            // 新的已存在就**不覆盖**：新数据优先，避免回退覆盖用户后来的改动
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
                copied.append(source.lastPathComponent)
            } catch {
                // 单个文件失败不影响其余
                continue
            }
        }
        guard !copied.isEmpty else { return nil }
        return "已从旧目录迁移 \(copied.count) 个文件：\(copied.joined(separator: ", "))"
    }

    /// 把旧 bundle id 域里的设置/快捷键搬过来（只填空缺项）。
    private static func migrateDefaults(defaults: UserDefaults) -> [String] {
        guard let legacy = UserDefaults(suiteName: legacyBundleID) else { return [] }

        // 普通设置项：键名不变，直接搬值
        let plainKeys = [
            "clearOnExit",
            "clearOnOpen",
            "restartOnEnd",
            "seekStepSeconds",
            "screenshotDirectory",
        ]
        var copied: [String] = []
        for key in plainKeys {
            guard defaults.object(forKey: key) == nil, let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            copied.append(key)
        }

        // 快捷键覆盖：存储键本身也带旧前缀（zephyr.hotkeys.overrides → gale.hotkeys.overrides）
        let legacyHotKeyKey = "zephyr.hotkeys.overrides"
        let currentHotKeyKey = "gale.hotkeys.overrides"
        if defaults.object(forKey: currentHotKeyKey) == nil,
           let value = legacy.object(forKey: legacyHotKeyKey) {
            defaults.set(value, forKey: currentHotKeyKey)
            copied.append(currentHotKeyKey)
        }

        return copied
    }
}
