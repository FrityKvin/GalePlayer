import Combine
import SwiftUI

/// 主窗口：普通模式 = 左侧视频舞台 + 控制条 + 右侧面板；
/// 全屏模式 = 纯视频画面，控制条/侧栏全部收起，鼠标活动时底部浮现浮动控制条
/// ，静止约 3 秒自动隐藏，Esc/↩ 退出全屏。
struct ContentView: View {
    @EnvironmentObject private var core: PlayerCore
    @EnvironmentObject private var settings: AppSettings
    @State private var sidebarVisible = true
    /// 拖放悬停高亮
    @State private var isDropTargeted = false
    /// 全屏下「鼠标贴近右缘」时显示箭头。
    /// 用 @ObservedObject 直接观察控制器，**不需要**再开定时器轮询状态。
    @ObservedObject private var edgeReveal = EdgeRevealController.shared
    @State private var sidebarTab: SidebarTab = .playlist
    @State private var isFullScreen = false
    @State private var overlayVisible = false
    @State private var hideTask: Task<Void, Never>?

    /// 全屏下鼠标静止多久后隐藏浮层（原版 autoHidePlaylistTime 默认 3 秒量级）。
    private let overlayAutoHide: Duration = .seconds(3)

    var body: some View {
        RenderCounters.contentView += 1   // 资源自检用：统计整棵视图树被重算的次数
        return ZStack(alignment: .bottom) {
            // 关键：视频舞台的**结构位置固定**，全屏只切换周边装饰（侧栏/控制条/工具栏）。
            //
            // 不能写成 `if isFullScreen { fullScreenStage } else { normalStage }` 然后各放一个
            // `VideoStage()` —— 那样切换全屏会销毁一个 MPVGLView、新建另一个，而一个 mpv 句柄
            // 只能有一个 render context，两个视图会互相抢：实测追踪显示它们来回 attach/detach，
            // 最终普通布局的视图抢到上下文、全屏视图没有 → 切一次全屏画面就不再渲染（并可能
            // 触发野指针崩溃 incident 5693B60E）。
            //
            // 现在 HSplitView 与其中的 VideoStage 恒在，只按 isFullScreen 增删后面的兄弟节点
            // （SwiftUI 的身份是「类型 + 在父节点中的位置」，删掉后面的兄弟不影响第一个子节点的身份）。
            HSplitView {
                VStack(spacing: 0) {
                    // 视频区 + 播放列表悬浮标签（20pt 真实列，见 PlaylistEdgeTab 的注释：
                    // 不能用 overlay 叠在视频上，NSOpenGLView 会吃掉悬停事件）
                    HStack(spacing: 0) {
                        VideoStage()
                            .frame(minWidth: 360, minHeight: 200)

                        PlaylistEdgeTab(
                            isPlaylistOpen: isFullScreen
                                ? core.isPlaylistFloating
                                : (sidebarVisible && sidebarTab == .playlist),
                            onToggle: { togglePlaylist() },
                            isRevealed: isFullScreen ? edgeReveal.isNearRightEdge : nil,
                            isOverlayMode: isFullScreen
                        )
                    }
                    if !isFullScreen {
                        Divider()
                        ControlBar(
                            sidebarVisible: $sidebarVisible,
                            sidebarTab: $sidebarTab
                        )
                    }
                }
                .frame(minWidth: isFullScreen ? 0 : 380)

                if sidebarVisible && !isFullScreen {
                    SidebarPanel(tab: $sidebarTab, visible: $sidebarVisible)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
                }
            }
            .ignoresSafeArea(edges: isFullScreen ? .all : [])
            // 全屏下鼠标移动唤起底部浮层（showOverlay 内部只在全屏生效）
            .onContinuousHover { _ in showOverlay() }
            .onMoveCommand { _ in showOverlay() }
            .statusMessageOverlay(core: core)
            // 拖放对**整个窗口**生效：拖到视频区、控制栏、播放列表都一样。
            // 文件夹一律扫描整个文件夹（不再出现「拖到播放窗口只播单个文件」）。
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleWindowDrop(providers)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.08))
                        .allowsHitTesting(false)
                }
            }

            // 滚轮/中键操作后的短暂提示（例如「音量 65%」「已恢复上次进度 12:34」）
            if let toast = core.toast {
                Text(toast)
                    .font(.system(.callout, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if isFullScreen {
                fullScreenOverlay
            }

            // 全屏时的播放列表浮层：贴右缘滑入，复用侧栏里的 PlaylistPanel
            if isFullScreen && core.isPlaylistFloating {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Spacer()
                            Button {
                                core.isPlaylistFloating = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("收起播放列表")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        Divider()

                        PlaylistPanel()
                    }
                    .frame(width: 320)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .trailing))
                }
                .animation(.easeInOut(duration: 0.2), value: core.isPlaylistFloating)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFullScreen)
        .animation(.easeInOut(duration: 0.2), value: core.toast)
        .onReceive(core.$isFullScreen) { value in
            isFullScreen = value
            if !value {
                overlayVisible = false
                core.isPlaylistFloating = false   // 退出全屏时收起浮层，避免残留
            }
        }
        .onAppear {
            let reveal = EdgeRevealController.shared
            reveal.start(window: NSApp.keyWindow)
            // 自动缩回：控制器判定鼠标离开足够远时回调这里
            reveal.onShouldCollapse = {
                guard core.isPlaylistFloating else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    core.isPlaylistFloating = false
                }
            }
        }
        .onDisappear {
            EdgeRevealController.shared.stop()
        }
        .toolbar(isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .navigationTitle(core.mediaTitle.isEmpty ? "Gale Player" : core.mediaTitle)
    }

    // MARK: - 全屏浮层

    /// 全屏浮层：仅底部一条渐隐材质控制条 + 顶部标题。
    @ViewBuilder
    private var fullScreenOverlay: some View {
        VStack {
            if overlayVisible {
                HStack {
                    Text(core.mediaTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 14)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .allowsHitTesting(overlayVisible)

        VStack {
            Spacer()
            if overlayVisible {
                ControlBar(
                    sidebarVisible: .constant(false),
                    sidebarTab: $sidebarTab,
                    showsSidebarToggle: false
                )
                .background(.ultraThinMaterial)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: 720)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: overlayVisible)
    }

    // MARK: - 播放列表悬浮

    /// 右缘箭头点击：普通窗口切换右侧面板，全屏切换浮层。
    /// 窗口级拖放：把拖入的文件/文件夹交给 `importDropped` 统一处理。
    ///
    /// 语义（全局一致，不再因落点而不同）：
    ///   - 文件夹 → **扫描整个文件夹**并加入播放列表；
    ///   - 文件   → 加入播放列表；
    ///   - 若此前没有在播放，自动从第一个开始播。
    private func handleWindowDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }

        // 等所有 provider 回调完再统一处理，避免多次落盘
        group.notify(queue: .main) {
            isDropTargeted = false
            guard !urls.isEmpty else { return }
            let count = core.importDropped(urls)
            core.showToast(dropMessage(fileCount: count, urls: urls))
        }
        return true
    }

    private func dropMessage(fileCount: Int, urls: [URL]) -> String {
        guard fileCount > 0 else { return "没有可导入的项目" }
        let folders = urls.filter { $0.hasDirectoryPath }.count
        let media = settings.orderedMedia.count
        if folders > 0 {
            return folders == 1
                ? "已扫描文件夹，播放列表共 \(media) 个媒体"
                : "已扫描 \(folders) 个文件夹，播放列表共 \(media) 个媒体"
        }
        return "已导入 \(fileCount) 个文件"
    }

    private func togglePlaylist() {
        if isFullScreen {
            core.isPlaylistFloating.toggle()
        } else if sidebarVisible && sidebarTab == .playlist {
            sidebarVisible = false
        } else {
            sidebarVisible = true
            sidebarTab = .playlist
        }
    }

    // MARK: - 浮层显隐

    private func showOverlay() {
        guard isFullScreen else { return }
        overlayVisible = true
        hideTask?.cancel()
        hideTask = Task { [overlayAutoHide] in
            try? await Task.sleep(for: overlayAutoHide)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                overlayVisible = false
            }
        }
    }
}

// MARK: - 状态提示胶囊

private extension View {
    @ViewBuilder
    func statusMessageOverlay(core: PlayerCore) -> some View {
        overlay(alignment: .bottom) {
            if let message = core.statusMessage {
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 92)
                    .transition(.opacity)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2))
                        core.statusMessage = nil
                    }
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: core.statusMessage)
    }
}
