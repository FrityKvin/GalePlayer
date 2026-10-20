import SwiftUI
import GaleCore

/// 设置面板：通用 / 快捷键 / 播放列表 三个标签页。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            HotKeySettings()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            PlaylistSettings()
                .tabItem { Label("播放列表", systemImage: "list.bullet") }
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("截图") {
                LabeledContent("保存位置") {
                    HStack {
                        Text(settings.screenshotDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…") { chooseDirectory() }
                    }
                }
            }
            Section("播放") {
                Toggle("播完自动播下一个", isOn: Binding(
                    get: { !settings.restartOnEnd },
                    set: { settings.setRestartOnEnd(!$0) }
                ))

                // 快进/快退秒数：1–60 秒，写入时自动夹取
                Stepper(
                    value: Binding(
                        get: { settings.seekStepSeconds },
                        set: { settings.setSeekStepSeconds($0) }
                    ),
                    in: AppSettings.seekStepRange,
                    step: 1
                ) {
                    LabeledContent("快进 / 快退") {
                        HStack(spacing: 4) {
                            Text("\(settings.seekStepSeconds)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text("秒").foregroundStyle(.secondary)
                        }
                    }
                }

                Text("左右方向键、控制栏 ⏪ ⏩ 与菜单「快退/快进 N 秒」都按这个步长走；长按 ⇧ 固定为 60 秒。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Section("更新") {
                Toggle("启动时自动检查更新（每天最多一次）", isOn: Binding(
                    get: { UpdateChecker.shared.automaticCheckEnabled },
                    set: { UpdateChecker.shared.automaticCheckEnabled = $0 }
                ))
                LabeledContent("当前版本", value: UpdateChecker.currentVersion)
                LabeledContent("更新来源", value: "GitHub · \(UpdateChecker.repository)")
            }
            Section("内核") {
                LabeledContent("播放内核", value: "libmpv（FFmpeg 9 / VideoToolbox 硬解）")
                LabeledContent("渲染方式", value: "libmpv render API（OpenGL）")
                LabeledContent("许可证", value: "libmpv 动态链接 · LGPL 路线可切换")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setScreenshotDirectory(url)
    }
}

// MARK: - 快捷键（可录制改绑）

private struct HotKeySettings: View {
    @EnvironmentObject private var hotKeys: HotKeyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(HotKeyAction.Category.allCases, id: \.rawValue) { category in
                        sectionHeader(category)
                        ForEach(HotKeyAction.allCases.filter { $0.category == category }, id: \.rawValue) { action in
                            row(for: action)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("快捷键")
                    .font(.headline)
                Text("点方框后按下新的组合键即可改绑，按 Esc 取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("全部恢复默认") { hotKeys.resetAll() }
                .controlSize(.small)
        }
        .padding(12)
    }

    private func sectionHeader(_ category: HotKeyAction.Category) -> some View {
        Text(category.rawValue)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func row(for action: HotKeyAction) -> some View {
        let combo = hotKeys.combo(for: action)
        let conflict = combo.flatMap { hotKeys.conflictingAction(for: $0, excluding: action) }
        let customized = hotKeys.isCustomized(action)

        return HStack(spacing: 10) {
            Text(action.title)
                .font(.callout)
            if customized {
                Text("已改")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let conflict {
                Label("与「\(conflict.title)」冲突", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            ShortcutRecorder(combo: combo) { captured in
                hotKeys.set(captured, for: action)
            }
            .frame(width: 128, height: 22)

            Menu {
                Button("恢复默认") { hotKeys.reset(action) }
                    .disabled(!customized)
                Button("清除绑定") { hotKeys.set(nil, for: action) }
                    .disabled(combo == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

// MARK: - 播放列表

private struct PlaylistSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("打开时") {
                Toggle("打开新文件时清空播放列表", isOn: Binding(
                    get: { settings.clearOnOpen },
                    set: { settings.setClearOnOpen($0) }
                ))
            }
            Section("退出时") {
                Toggle("退出时清空播放列表", isOn: Binding(
                    get: { settings.clearOnExit },
                    set: { settings.setClearOnExit($0) }
                ))
                Toggle("退出时清空最近播放", isOn: Binding(
                    get: { settings.clearOnExit },
                    set: { settings.setClearOnExit($0) }
                ))
            }
            Section("显示") {
                Toggle("图文模式（显示缩略图）", isOn: $settings.imageMode)
                LabeledContent("当前列表项", value: "\(settings.orderedMedia.count) 个文件")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
