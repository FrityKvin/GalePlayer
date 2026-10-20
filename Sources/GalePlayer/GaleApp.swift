import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GaleCore

@main
struct GaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var core: PlayerCore
    @StateObject private var hotKeys: HotKeyStore

    init() {
        // 改名迁移必须放在**最前面**：它要赶在任何一处读取之前完成。
        // 设置与快捷键存在 UserDefaults（落盘域 = bundle id），
        // 播放列表/关键帧/播放进度存在 Application Support/<bundle-id>/，
        // 改 bundle id 后若不做迁移，这些数据会"凭空消失"。
        let migrationReport = GaleMigration.runIfNeeded()
        if !migrationReport.isEmpty {
            for line in migrationReport { NSLog("Gale 迁移：\(line)") }
        }

        // 自检模式：不开 GUI，直接把 mpv 加载/解码/渲染结果打出来
        if Diagnostics.isRequested() {
            Diagnostics.run()
        }
        // 快捷键自检：打印当前生效键位表
        if HotKeyReport.isRequested() {
            HotKeyReport.run()
        }
        // 播放列表扫描自检：验证文件夹导入的扁平化结果
        if FolderScanReport.isRequested() {
            FolderScanReport.run()
        }
        // 视频视图生命周期自检：防 use-after-free 回归
        if LifecycleTest.isRequested() {
            LifecycleTest.run()
        }
        // 更新检查自检：真实走一遍「拉 GitHub latest release → 比版本 → 出决策」，
        // 不弹 UI、不落任何 UserDefaults。仓库可用 GALE_UPDATE_REPO 覆盖。
        if ProcessInfo.processInfo.arguments.contains("--update-check") {
            UpdateCheckReport.run()
        }

        let directory = AppPaths.supportDirectory
        let settings = AppSettings(directory: directory)
        let core = PlayerCore(
            settings: settings,
            chapterStore: ChapterStore(directory: directory)
        )
        _settings = StateObject(wrappedValue: settings)
        _core = StateObject(wrappedValue: core)
        _hotKeys = StateObject(wrappedValue: HotKeyStore())
    }

    var body: some Scene {
        WindowGroup("Gale") {
            ContentView()
                .environmentObject(core)
            .environmentObject(core.clock)
                .environmentObject(settings)
                .environmentObject(hotKeys)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear {
                    AppDelegate.core = core
                    AppDelegate.settings = settings
                    AppDelegate.installFullScreenObserver()
                    // 接管方向键/空格/功能键等菜单注册不了的快捷键
                    HotKeyMonitor.install(core: core, hotKeys: hotKeys)

                    if WindowReport.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(6))
                            WindowReport.dump()
                            try? await Task.sleep(for: .seconds(2))
                            NSApp.terminate(nil)
                        }
                    }

                    // 真实 UI 视图重建自检：反复切全屏/换片，验证视图拆卸与重建不出事
                    if UIRebuildTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(6))
                            UIRebuildTest.run(core: core)
                        }
                    }

                    // 菜单与 ⌘Q 路由自检
                    if MenuTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(4))
                            MenuTest.run()
                        }
                    }

                    // 滚轮冲突自检：播放列表上滚轮不应触发音量，视频区应触发
                    if ScrollConflictTest.isRequested() {
                        ScrollConflictTest.start(core: core)
                    }

                    // 按键通路自检：合成 ←/→/空格，验证快捷键真的生效
                    if InputTest.isRequested() {
                        Task { @MainActor in
                            // 与 UIRebuildTest 对齐：等首帧/视图稳定后再开始
                            try? await Task.sleep(for: .seconds(6))
                            InputTest.start(core: core, settings: settings)
                        }
                    }

                    // 真实 GUI 实例的资源采样落盘（launchctl setenv GALE_RESOURCE_DUMP 时生效）
                    core.installGlobalInput()

                    ResourceDump.startIfRequested(core: core)
                    ResourceDump.scheduleAutoPauseIfRequested(core: core)
                    ResourceDump.scheduleAutoAdvanceIfRequested(core: core)

                    // 命中测试诊断：定位「点不动」是事件被挡还是视图被禁
                    if HitTestReport.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            HitTestReport.start(core: core)
                        }
                    }

                    // 鼠标交互自检：单击=播放/暂停、双击=进出全屏
                    if MouseTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            MouseTest.start(core: core)
                        }
                    }

                    // 文件夹高亮 · 真实路径自检（拖入文件夹 → 点列表 → 点下一个）
                    if FolderHighlightTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            FolderHighlightTest.start(core: core, settings: settings)
                        }
                    }

                    // 播放列表高亮自检：验证「正在播放项」的判定是否真的成立
                    if HighlightTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            HighlightTest.start(core: core, settings: settings)
                        }
                    }

                    // 资源占用自检：CPU / 内存 / 线程 / 视图重算频率
                    if ResourceReport.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(5))
                            ResourceReport.start(core: core)
                        }
                    }

                    // 播放进度记忆自检：记录 → 落盘 → 重读 → 恢复
                    if ResumeTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(6))
                            ResumeTest.start(core: core, settings: settings)
                        }
                    }

                    // 播放列表导出自检：走真实导出路径，校验关键帧是否写进文件
                    if PlaylistExportTest.isRequested() {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(6))
                            PlaylistExportTest.start(core: core, settings: settings)
                        }
                    }

                    core.onPlaybackEnded = { [core, settings] in
                        if settings.restartOnEnd {
                            core.seek(to: 0)
                        } else {
                            core.playNext()
                        }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            GaleCommands(core: core, settings: settings, hotKeys: hotKeys)
        }

        Settings {
            SettingsView()
                .environmentObject(core)
                .environmentObject(settings)
                .environmentObject(hotKeys)
        }
    }
}

/// 菜单与快捷键。
///
/// 键位设计沿用经典播放器习惯：媒体切换 ⌘↑/⌘↓，关键帧跳转 ⌘N/⌘P。
///
/// 所有快捷键都从 `HotKeyStore` 读取，因此设置页改绑后菜单立即生效。
struct GaleCommands: Commands {
    @ObservedObject var core: PlayerCore
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyStore

    var body: some Commands {
        // 应用菜单：检查更新（放在「关于」旁边，macOS 惯例）
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                UpdateChecker.shared.checkManually(core: core)
            }
        }

        // 文件
        CommandGroup(replacing: .newItem) {
            Button("打开文件…") { openFiles() }
                .applying(hotKeys.combo(for: .openFile))
            Button("打开文件夹…") { openFolder() }
                .applying(hotKeys.combo(for: .openFolder))
            Divider()
            Divider()
            Button("导出播放列表…") { core.exportPlaylist() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("导入播放列表…") { core.importPlaylist() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Menu("最近播放") {
                if settings.recents.isEmpty {
                    Text("（空）")
                } else {
                    ForEach(settings.recents, id: \.self) { url in
                        Button(url.lastPathComponent) { core.open(urls: [url]) }
                    }
                    Divider()
                    Button("清空最近播放") { settings.clearRecents() }
                }
            }
        }

        // 播放
        CommandMenu("播放") {
            Button("播放/暂停") { core.perform(.playPause) }
                .applying(hotKeys.combo(for: .playPause))
            Button("停止") { core.perform(.stop) }
                .applying(hotKeys.combo(for: .stop))

            Divider()

            Button("快退 \(core.seekStepSeconds) 秒") { core.perform(.seekBackward) }
                .applying(hotKeys.combo(for: .seekBackward))
            Button("快进 \(core.seekStepSeconds) 秒") { core.perform(.seekForward) }
                .applying(hotKeys.combo(for: .seekForward))
            Button("快退 60 秒") { core.perform(.seekBackwardLong) }
                .applying(hotKeys.combo(for: .seekBackwardLong))
            Button("快进 60 秒") { core.perform(.seekForwardLong) }
                .applying(hotKeys.combo(for: .seekForwardLong))

            Divider()

            Button("上一个视频") { core.perform(.previousMedia) }
                .applying(hotKeys.combo(for: .previousMedia))
            Button("下一个视频") { core.perform(.nextMedia) }
                .applying(hotKeys.combo(for: .nextMedia))

            Divider()

            Button("加速播放") { core.perform(.speedUp) }
                .applying(hotKeys.combo(for: .speedUp))
            Button("减速播放") { core.perform(.speedDown) }
                .applying(hotKeys.combo(for: .speedDown))
            Button("恢复常速") { core.perform(.speedReset) }
                .applying(hotKeys.combo(for: .speedReset))
            Menu("播放速度") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button(String(format: "%.2gx", speed)) { core.setSpeed(speed) }
                }
            }

            Divider()

            Button("提高音量") { core.perform(.volumeUp) }
                .applying(hotKeys.combo(for: .volumeUp))
            Button("降低音量") { core.perform(.volumeDown) }
                .applying(hotKeys.combo(for: .volumeDown))
            Button("静音") { core.perform(.mute) }
                .applying(hotKeys.combo(for: .mute))

            Divider()

            Button("截图") { core.perform(.screenshot) }
                .applying(hotKeys.combo(for: .screenshot))
            Button("全屏") { core.perform(.fullScreen) }
                .applying(hotKeys.combo(for: .fullScreen))
            Button("窗口置顶") { core.perform(.alwaysOnTop) }
                .applying(hotKeys.combo(for: .alwaysOnTop))
        }

        // 关键帧
        CommandMenu("关键帧") {
            Button("添加关键帧") { core.perform(.chapterAdd) }
                .applying(hotKeys.combo(for: .chapterAdd))
            Button("删除关键帧") { core.perform(.chapterDelete) }
                .applying(hotKeys.combo(for: .chapterDelete))

            Divider()

            Button("上一个关键帧") { core.perform(.chapterPrevious) }
                .applying(hotKeys.combo(for: .chapterPrevious))
            Button("下一个关键帧") { core.perform(.chapterNext) }
                .applying(hotKeys.combo(for: .chapterNext))

            Divider()

            Toggle("关键帧之间循环", isOn: $core.loopChapters)

            Divider()

            Button("导出关键帧…") { core.exportChapters() }
            Button("导入关键帧…") { core.importChapters() }
            Button("清空全部关键帧", role: .destructive) { core.removeAllChapters() }
        }

        CommandGroup(replacing: .saveItem) { }
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaTypes.all.sorted().compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        core.open(urls: panel.urls)
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        core.open(urls: [url])
    }
}
