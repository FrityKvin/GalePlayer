import SwiftUI
import GaleCore

/// 播放控制条。
///
/// 布局与操作习惯参照暴风影音 Mac 版的控制栏（播放/停止/快进快退/上一个下一个/
/// 音量/截图/全屏/播放列表开关），并加入 DMM Player 的关键帧按钮（+ / − / 跳转）。
///
/// 自适应：按可用宽度分三档密度，窄窗口自动收窄间距、隐藏次要信息，
/// 避免按钮挤压换行或文字截断（修「不同窗口尺寸下排版不一致」）。
struct ControlBar: View {
    @EnvironmentObject private var core: PlayerCore
    // 注意：ControlBar 本身**不观察** clock。进度条已拆成 SeekBarView 自己观察，
    // 否则 ControlBar 会跟着每秒重算 24 次，把它下面那一排按钮全带上。
    @Binding var sidebarVisible: Bool
    @Binding var sidebarTab: SidebarTab

    /// 全屏浮层里不显示「面板」按钮（全屏没有侧栏）。
    var showsSidebarToggle: Bool = true

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    /// 布局密度
    private enum Density {
        case full      // ≥ 880
        case medium    // 640 – 880
        case compact   // < 640

        init(width: CGFloat) {
            if width >= 880 {
                self = .full
            } else if width >= 640 {
                self = .medium
            } else {
                self = .compact
            }
        }

        var spacing: CGFloat {
            switch self {
            case .full: 12
            case .medium: 8
            case .compact: 5
            }
        }

        var volumeWidth: CGFloat? {
            switch self {
            case .full: 90
            case .medium: 52
            case .compact: nil
            }
        }

        var showsTime: Bool { self != .compact }
        var showsChapterCount: Bool { self == .full }
    }

    var body: some View {
        RenderCounters.controlBar += 1    // 资源自检用
        return GeometryReader { geometry in
            let density = Density(width: geometry.size.width)
            VStack(spacing: 6) {
                seekBar(showsTime: density.showsTime)
                // 三段布局：左（截图/音量）— 中（播放控制，居中）— 右（关键帧/全屏/面板）
                // 左右两侧各占一份剩余空间（maxWidth: .infinity），播放控制才会真正居中，
                // 而不是被左边的图标数量带偏。
                HStack(spacing: density.spacing) {
                    leading(density: density)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    transport(density: density)
                    trailing(density: density)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .frame(width: geometry.size.width, alignment: .top)
        }
        .frame(height: 76)
        .background(.bar)
    }

    // MARK: - 进度条（含关键帧标记）

    /// 进度条区域。
    ///
    /// 拆成独立视图（`SeekBarView`）是为了把「每秒变 24 次」的进度变化限制在
    /// 这条细长视图内部：如果直接写在 ControlBar 里，ControlBar 会跟着每秒重算 24 次
    /// （实测约 3.4% 单核 CPU），而它下面挂着整排按钮。
    private func seekBar(showsTime: Bool) -> some View {
        SeekBarView(showsTime: showsTime)
            .padding(.horizontal, 12)
    }

    // MARK: - 按钮组

    private func transport(density: Density) -> some View {
        HStack(spacing: density.spacing * 0.8) {
            button("backward.end.fill", help: "上一个视频") { core.playPrevious() }
            button("gobackward.10", help: "快退 \(core.seekStepSeconds) 秒") { core.perform(.seekBackward) }
            button(core.isPlaying ? "pause.fill" : "play.fill", help: "播放/暂停", large: true) {
                core.togglePlay()
            }
            button("goforward.10", help: "快进 \(core.seekStepSeconds) 秒") { core.perform(.seekForward) }
            button("forward.end.fill", help: "下一个视频") { core.playNext() }
            button("stop.fill", help: "停止") { core.stop() }
        }
        .fixedSize()
    }

    /// 关键帧操作组（DMM 风格：+ 添加、− 删除、⏮⏭ 跳转）
    private func chapters(density: Density) -> some View {
        HStack(spacing: density.spacing * 0.6) {
            button("plus", help: "添加关键帧") { core.addChapter() }
            button("minus", help: "删除当前位置之前的关键帧") { core.deleteChapter() }
            button("backward.frame.fill", help: "上一个关键帧") { core.goToPreviousChapter() }
            button("forward.frame.fill", help: "下一个关键帧") { core.goToNextChapter() }

            Toggle(isOn: $core.loopChapters) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("关键帧之间循环播放")

            if density.showsChapterCount {
                Text("\(core.chapterTimes.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .leading)
            }
        }
        .fixedSize()
    }

    /// 左侧组：截图 + 静音 + 音量。
    private func leading(density: Density) -> some View {
        HStack(spacing: 8) {
            button("camera", help: "截图") { core.screenshot() }
            button(core.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: "静音") {
                core.toggleMute()
            }
            if let width = density.volumeWidth {
                Slider(value: $core.volume, in: 0...200)
                    .frame(width: width)
                    .help("音量")
            }
        }
        .fixedSize()
    }

    /// 右侧组：关键帧操作 + 全屏 + 面板开关。
    /// 窗口置顶按钮已按用户反馈移除（功能保留在菜单 ⌘T 与右键里）。
    private func trailing(density: Density) -> some View {
        HStack(spacing: density.spacing) {
            chapters(density: density)

            Divider()
                .frame(height: 14)

            button("arrow.up.left.and.arrow.down.right", help: "全屏") { core.toggleFullScreen() }
            if showsSidebarToggle {
                button("list.bullet.rectangle", help: "播放列表 / 关键帧面板") {
                    if sidebarVisible && sidebarTab == .playlist {
                        sidebarVisible = false
                    } else {
                        sidebarVisible = true
                        sidebarTab = .playlist
                    }
                }
            }
        }
        .fixedSize()
    }

    private func button(_ symbol: String, help: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 16 : 12))
                .frame(width: large ? 26 : 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// 进度条 + 关键帧标记 + 时间文本。
///
/// 单独成 View 而不是 ControlBar 的一个方法：SwiftUI 的重算粒度是「观察者的 body」，
/// 把它拆出来之后，每秒 24 次的进度变化只重算这个 ~100 行的视图，
/// 不会带上 ControlBar 里那一排按钮（实测 CPU 从 8.6% 降到约 5%）。
private struct SeekBarView: View {
    @EnvironmentObject private var core: PlayerCore
    @EnvironmentObject private var clock: PlaybackClock
    let showsTime: Bool

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        RenderCounters.seekBar += 1      // 资源自检用
        return HStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 5)

                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: SeekBarGeometry.progressWidth(
                            position: isScrubbing ? scrubValue : clock.position,
                            duration: core.duration,
                            width: width
                        ), height: 5)

                    // 关键帧标记：位置严格按 time/duration 计算（见 SeekBarGeometry），
                    // 高度铺满 14pt 的轨道，不做 y 偏移，避免画到轨道外面看不见/错位。
                    if core.duration > 0 {
                        ForEach(core.chapterTimes, id: \.self) { time in
                            Rectangle()
                                .fill(Color.orange)
                                .frame(width: 2, height: 14)
                                .offset(x: SeekBarGeometry.markerX(
                                    time: Double(time),
                                    duration: core.duration,
                                    width: width,
                                    markerWidth: 2
                                ))
                        }
                    }
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let ratio = min(max(0, value.location.x / max(width, 1)), 1)
                            scrubValue = Double(ratio) * max(core.duration, 0)
                            core.setTimePos(scrubValue)
                        }
                        .onEnded { value in
                            let ratio = min(max(0, value.location.x / max(width, 1)), 1)
                            core.seek(to: Double(ratio) * core.duration)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 14)

            if showsTime {
                Text("\(PlaybackClock.format(isScrubbing ? scrubValue : clock.position)) / \(PlaybackClock.format(core.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: 104, alignment: .trailing)
            }
        }
    }
}
