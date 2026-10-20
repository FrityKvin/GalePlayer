import AppKit
import Foundation
import GaleCore

/// 按键通路自检：合成真实按键事件，验证快捷键**真的生效**。
///
/// 背景：菜单自检发现方向键/空格/回车/功能键的菜单 `keyEquivalent` 全是空字符串，
/// 也就是这些快捷键从来没生效过；现在改由 `HotKeyMonitor` 接管，必须实测确认。
///
/// ⚠️ 写法陷阱（本文件第一版就踩了）：自检主体**不能**写成 `@MainActor` 的 Task 里
/// 自旋 run loop。Swift 的 main actor 是「执行器」：Task 主体执行期间它被独占，
/// 其他 `Task { @MainActor }`（也就是 mpv 的属性/事件回调）永远排不上队，
/// 于是 duration / isLoading 一直不更新，看起来像「文件根本加载不出来」。
/// 正确做法：主体放后台线程，读写主线程状态用 `DispatchQueue.main.sync` 逐次进入，
/// 两次调用之间 main actor 是空闲的，mpv 回调才能被处理。
///
/// 用法：GalePlayer --input-test <媒体文件>
enum InputTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--input-test")
    }

    /// 在主线程上启动，随后把主体丢到后台线程。
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

    // MARK: - 主体（后台线程）

    private static func perform(core: PlayerCore, settings: AppSettings) {
        var lines: [String] = ["按键通路自检"]

        guard let index = CommandLine.arguments.firstIndex(of: "--input-test"),
              CommandLine.arguments.count > index + 1 else {
            report("  失败：缺少媒体文件参数")
            NSApp.terminate(nil)
            return
        }
        let mediaURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])

        lines.append("  按键监视器已安装=\(onMain { HotKeyMonitor.isInstalled })")

        onMain { core.open(urls: [mediaURL]) }

        // 等真正拿到时长（mpv 回调要在 main actor 空闲时才能被处理）
        let deadline = Date().addingTimeInterval(25)
        var duration = onMain { core.duration }
        while duration <= 0, Date() < deadline {
            spin(seconds: 0.4)
            duration = onMain { core.duration }
        }
        guard duration > 0 else {
            let state = onMain {
                "currentURL=\(core.currentURL?.lastPathComponent ?? "nil") "
                    + "isLoading=\(core.isLoading) isPlaying=\(core.isPlaying) "
                    + "可渲染=\(core.isVideoViewRenderable)"
            }
            report((lines + ["  失败：媒体未加载", "  诊断：\(state)"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        lines.append("  媒体已加载，时长 \(SeekBarGeometry.timeText(duration))")

        onMain { core.seek(to: 100) }
        spin(seconds: 0.8)

        // 步长设置：默认 10 秒，改成 3 秒验两次
        let defaultStep = onMain { settings.seekStepSeconds }
        lines.append("  当前快进/快退步长=\(defaultStep) 秒（范围 \(AppSettings.seekStepRange.lowerBound)-\(AppSettings.seekStepRange.upperBound)）")
        onMain { settings.setSeekStepSeconds(3) }
        spin(seconds: 0.3)
        lines.append("  设为 3 秒后=\(onMain { settings.seekStepSeconds })")

        // ← 键（keyCode 123）：应后退 3 秒
        let beforeBack = onMain { core.mpvTimePos ?? core.timePos }
        sendKey(characters: KeyCombo.SpecialKey.left, keyCode: 123)
        spin(seconds: 1.0)
        let afterBack = onMain { core.mpvTimePos ?? core.timePos }
        let backOK = afterBack < beforeBack - 1
        let backDiag = "解析=\(onMain { HotKeyMonitor.debugLastParsed }) 命中=\(onMain { HotKeyMonitor.debugLastMatched }) 事件数=\(onMain { HotKeyMonitor.debugEventCount })"
        lines.append("  ← 键：\(fmt(beforeBack)) → \(fmt(afterBack))（应 -3s）\(backOK ? " ✓" : " ✗")  [\(backDiag)]")

        // 直接调用 seek(by:)，用来区分「按键没到」与「seek 本身没生效」
        let beforeDirect = onMain { core.mpvTimePos ?? core.timePos }
        onMain { core.seek(by: -3) }
        spin(seconds: 1.0)
        let afterDirect = onMain { core.mpvTimePos ?? core.timePos }
        lines.append("  直接 seek(by:-3)：\(fmt(beforeDirect)) → \(fmt(afterDirect))\(afterDirect < beforeDirect - 1 ? " ✓" : " ✗")")

        // → 键（keyCode 124）：应前进 3 秒
        sendKey(characters: KeyCombo.SpecialKey.right, keyCode: 124)
        spin(seconds: 1.0)
        let afterForward = onMain { core.mpvTimePos ?? core.timePos }
        let forwardOK = afterForward > afterBack + 1
        lines.append("  → 键：\(fmt(afterBack)) → \(fmt(afterForward))（应 +3s）\(forwardOK ? " ✓" : " ✗")")

        // 空格：播放/暂停
        let playingBefore = onMain { core.isPlaying }
        sendKey(characters: " ", keyCode: 49)
        spin(seconds: 1.0)
        let playingAfter = onMain { core.isPlaying }
        let spaceOK = playingBefore != playingAfter
        lines.append("  空格：播放 \(playingBefore) → \(playingAfter)\(spaceOK ? " ✓" : " ✗")")
        if playingBefore {
            onMain { core.togglePlay() }
            spin(seconds: 0.6)
        }

        // 夹取：0 → 1，999 → 60
        onMain { settings.setSeekStepSeconds(0) }
        let lowClamped = onMain { settings.seekStepSeconds }
        onMain { settings.setSeekStepSeconds(999) }
        let highClamped = onMain { settings.seekStepSeconds }
        lines.append("  写入 0 → \(lowClamped)，写入 999 → \(highClamped)（应 1 / 60）\(lowClamped == 1 && highClamped == 60 ? " ✓" : " ✗")")
        onMain { settings.setSeekStepSeconds(defaultStep) }

        let allOK = backOK && forwardOK && spaceOK && lowClamped == 1 && highClamped == 60
        lines.append(allOK ? "  结论：按键通路全部生效 ✓" : "  结论：存在未生效的按键 ✗")
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    // MARK: - 工具

    /// 在主线程上执行并返回结果（后台线程专用）。
    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// 合成一次无修饰键的 keyDown，走真实事件分发（会经过 HotKeyMonitor）。
    private static func sendKey(characters: String, keyCode: UInt16) {
        let sent = onMain { () -> Bool in
            guard let window = NSApp.windows.first,
                  let event = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                  ) else { return false }
            NSApp.sendEvent(event)
            return true
        }
        if !sent { report("  警告：无法合成按键 \(keyCode)") }
    }

    private static func spin(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func fmt(_ seconds: Double) -> String {
        SeekBarGeometry.timeText(seconds)
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}