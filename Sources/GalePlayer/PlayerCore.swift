import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GaleCore

/// 侧边栏标签：播放列表与关键帧两个面板。
enum SidebarTab: String, CaseIterable, Identifiable {
    case playlist = "播放列表"
    case chapters = "关键帧"
    var id: String { rawValue }
}

/// 播放核心：持有 mpv 实例、当前关键帧集合、播放队列。
@MainActor
final class PlayerCore: ObservableObject {
    // 播放状态
    @Published private(set) var isPlaying = false
    /// 播放进度（**故意不是 @Published**）。
    ///
    /// 原因：`timePos` 每秒变几十次，而 `@EnvironmentObject` 的语义是
    /// 「对象上任何 @Published 变化都让整个视图重算」。早前把它放在 PlayerCore 上，
    /// 导致播放时 ContentView 每秒重算 24-36 次（整棵视图树，含播放列表），
    /// 实测这一项就吃掉约 9 个百分点的单核 CPU（13.6% → 4.6%）。
    ///
    /// 现在进度走 `clock`，只有真正显示进度的 ControlBar 会重算。
    var timePos: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var mediaTitle: String = ""
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var isFullScreen = false

    // 音量
    @Published var volume: Double = 60 {
        didSet { if !isSyncingFromCore { client?.setVolume(volume) } }
    }
    @Published var isMuted = false {
        didSet { if !isSyncingFromCore { client?.setMuted(isMuted) } }
    }

    // 关键帧（Chapter 体系）
    @Published private(set) var chapterBook: ChapterBook?
    @Published var loopChapters = false

    // 播放队列
    @Published private(set) var queue = PlaybackQueue()
    @Published var isAlwaysOnTop = false {
        didSet { applyAlwaysOnTop() }
    }

    /// 全屏下播放列表浮层的展开状态（普通窗口用右侧面板，无需此状态）。
    @Published var isPlaylistFloating = false

    /// 画面旋转（0/90/180/270，正值=顺时针）。
    @Published private(set) var videoRotation = 0
    /// 画面是否镜像（水平翻转）。
    @Published private(set) var isMirrored = false

    /// 音量/进度被滚轮或中键改变时的短暂提示（例如「音量 65%」）。
    @Published var toast: String?

    /// 窗口级输入监听器（滚轮 / 中键，对整个窗口生效）
    private var globalInputObservers: [NSObjectProtocol] = []

    /// 播放进度记忆（对应原版「记住播放进度」）
    private let historyURL: URL
    private var history = PlaybackHistory()
    private var historyTimer: DispatchSourceTimer?

    @Published var statusMessage: String?

    private var client: MPVClient?
    private var videoView: MPVGLView?
    private let chapterStore: ChapterStore
    private let settings: AppSettings
    private var isSyncingFromCore = false
    private var lastLoopJump = Date.distantPast
    private var currentSpeed: Double = 1

    var onPlaybackEnded: (() -> Void)?

    init(settings: AppSettings, chapterStore: ChapterStore) {
        self.settings = settings
        self.chapterStore = chapterStore
        self.historyURL = settings.directory.appendingPathComponent("playback-history.json")
        self.history = PlaybackHistory.load(from: historyURL)
    }

    // MARK: - 视图挂载

    func attach(glView: MPVGLView) {
        // 一个 mpv 句柄只能有一个 render context。SwiftUI 重建视图时会先建新视图、
        // 再交到这里；旧视图若不同步拆卸，它的 render context 会一直占着句柄，
        // 新视图创建时就会失败（mpv_render_context_create 返回 -20）。
        if let previous = videoView, previous !== glView {
            previous.detach()
        }
        guard let client = ensureClient() else { return }
        glView.prepare(with: client)
        videoView = glView

        // 视图晚于文件挂上时补一次加载。
        //
        // 场景：首启双击关联文件、拖入文件早于首帧、自检抢跑 —— 此时渲染上下文
        // 还不存在，而 `vo=libmpv` 没有上下文就打不开文件（表现为 duration 恒为 0、
        // 画面不动、也不报错）。等上下文就绪后重发一次即可。
        if let node = queue.current, currentURL != nil, duration == 0 {
            client.loadFile(node.url)
        }
    }

    /// 取（必要时创建）mpv 实例。
    ///
    /// 之前实例只在 `attach(glView:)` 里创建，于是「视图还没挂上就打开文件」
    /// （双击关联文件、拖入、⌘O 抢在首帧之前）会静默失败：
    /// `currentURL` 已改但文件根本没进 mpv（duration 恒为 0）。
    @discardableResult
    private func ensureClient() -> MPVClient? {
        if let client { return client }
        guard let created = MPVClient() else {
            statusMessage = "libmpv 初始化失败，请确认已安装 mpv"
            return nil
        }
        created.onProperty = { [weak self] name, value in
            Task { @MainActor in self?.handleProperty(name, value) }
        }
        created.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleEvent(event) }
        }
        client = created
        created.setVolume(volume)
        created.setMuted(isMuted)
        return created
    }

    func detach() {
        stopHistoryTimer()
        (videoView as? MPVGLView)?.detach()
        client?.destroy()
        client = nil
        videoView = nil
    }

    /// UI 用播放进度时钟：只有观察它的视图（进度条）会随进度重算。
    let clock = PlaybackClock()

    /// 进度推送到 clock 的阈值（秒）。0.04 秒 ≈ 25 次/秒；
    /// 因为只有 ControlBar 这个小视图会重算，可以放得比之前细得多、更顺滑。
    private static let timePosPublishThreshold: Double = 0.04

    /// 同时更新内部进度与 UI 时钟。
    ///
    /// 凡是**显式**改写进度的路径都必须成对更新（seek、恢复上次进度、拖动进度条），
    /// 否则会出现「已经跳过去了，进度条还停在旧位置」。
    func setTimePos(_ value: Double) {
        timePos = value
        clock.position = value
    }

    /// 供自检/排障：直接问 mpv 当前播放位置（不等属性回调）。
    var mpvTimePos: Double? { client?.currentTimePos() }

    /// 当前实际生效的硬解模式（自检/排障用）
    var hwdecCurrent: String { client?.getString("hwdec-current") ?? "?" }

    /// 供自检使用：当前挂载的视频视图是否已建好渲染上下文。
    /// 全屏切换会重建视图，若旧上下文没释放，新视图会创建失败（-20）→ 这里为 false。
    var isVideoViewRenderable: Bool { videoView?.hasRenderContext ?? false }

    // MARK: - mpv 回调

    private func handleProperty(_ name: String, _ value: MPVValue) {
        switch name {
        case "time-pos":
            if let v = value.doubleValue, v.isFinite {
                timePos = v
                enforceChapterLoop(at: v)
                if abs(v - clock.position) >= Self.timePosPublishThreshold {
                    clock.position = v
                }
            }
        case "duration":
            if let v = value.doubleValue, v.isFinite { duration = v }
        case "pause":
            if let v = value.boolValue { isPlaying = !v }
        case "volume":
            syncFromCore { if let v = value.doubleValue { volume = v } }
        case "mute":
            syncFromCore { if let v = value.boolValue { isMuted = v } }
        case "media-title":
            if let v = value.stringValue, !v.isEmpty { mediaTitle = v }
        case "eof-reached":
            if value.boolValue == true { /* 由 END_FILE 事件处理自动续播 */ }
        default:
            break
        }
    }

    private func handleEvent(_ event: String) {
        switch event {
        case "file-loaded":
            isLoading = false
            applyResumePositionIfNeeded()
        case "eof":
            onPlaybackEnded?()
        case "end-file":
            isLoading = false
        default:
            break
        }
    }

    /// 避免 mpv 回写属性时触发 didSet 再发指令造成回环。
    private func syncFromCore(_ body: () -> Void) {
        isSyncingFromCore = true
        body()
        isSyncingFromCore = false
    }

    // MARK: - 打开媒体

    func open(urls: [URL], replacingQueue: Bool = true) {
        let playable = urls.filter { MediaTypes.isSupported($0) || isDirectory($0) }
        guard !playable.isEmpty else {
            statusMessage = "没有可播放的文件"
            return
        }

        let nodes = playable.flatMap { url -> [PlaylistNode] in
            isDirectory(url) ? Playlist.folderNode(for: url).flattenedMedia : Playlist.mediaNodes(from: [url])
        }
        guard !nodes.isEmpty else {
            statusMessage = "没有可播放的文件"
            return
        }

        // 队列要**以播放列表为主体**，而不是只有「这次打开的这一个文件」。
        //
        // 旧实现 `queue = PlaybackQueue(items: nodes)` → 用「打开方式」播一个文件后，
        // 队列里只有它一个 → 点「下一个」没有下一项 → currentURL 不变 →
        // 播放列表的高亮卡在第一项不动。
        //
        // 现在：队列 = 播放列表里已有的媒体 + 本次新打开的（去重、保持播放列表顺序），
        // 再把播放位置定位到本次要播的那一个。
        // 不能只取播放列表 —— 否则「打开一个不在列表里的文件」会播成列表里的第一个。
        // 目标文件（文件夹则取它的第一个媒体）
        let target = nodes.first.flatMap { first -> PlaylistNode? in
            first.resolvedIsFolder ? first.flattenedMedia.first : first
        }

        // 队列 = 播放列表已有 + 本次新开的（去重，保持播放列表顺序）
        var merged = settings.orderedMedia
        if let target, !merged.contains(where: { Self.sameFile($0.url, target.url) }) {
            merged.append(target)
        }
        if merged.isEmpty { merged = nodes }

        // 定位到目标。**定位不到时不能默默回退到 0** ——
        // 那会播成列表里的第一个文件（表现为「打开 A 却播了 B」，
        // 进度与高亮全都记在 B 上）。
        let startAt: Int
        if let target, let idx = merged.firstIndex(where: { Self.sameFile($0.url, target.url) }) {
            startAt = idx
        } else {
            startAt = 0
            merged = nodes.isEmpty ? merged : nodes      // 播本次指定的，而不是列表第一项
        }
        queue = PlaybackQueue(items: merged, startAt: startAt)
        playCurrent()
    }

    /// 播放列表里点某一项。
    ///
    /// `items` 是**队列**（`orderedMedia`，只有媒体文件），而 `node` 可能来自
    /// `playlistItems`（顶层节点，含文件夹 toggle）。因此不能直接
    /// `items.firstIndex(of: node)`：
    ///   - `PlaylistNode: Equatable` 是**逐字段**比较（含 id 与 children），
    ///     文件夹 toggle 与队列里的媒体项永远不相等 → 恒为 nil；
    ///   - 即使相等，文件夹 toggle 也不在队列里，语义上应从它**第一个媒体**开始。
    ///
    /// 改为按 URL 定位：文件夹 → 从它的第一个媒体项起播；文件 → 精确定位。
    func play(node: PlaylistNode, in items: [PlaylistNode]) {
        let startAt: Int
        if node.resolvedIsFolder {
            let firstURL = node.flattenedMedia.first?.url
            startAt = firstURL.flatMap { url in
                items.firstIndex { Self.sameFile($0.url, url) }
            } ?? 0
        } else {
            startAt = items.firstIndex { Self.sameFile($0.url, node.url) } ?? 0
        }
        queue = PlaybackQueue(items: items, startAt: startAt)
        playCurrent()
    }

    /// 播放列表里被判为「正在播放」的行数（诊断用：正常应为 1）。
    var highlightMatchCount: Int {
        guard let current = currentURL else { return -1 }
        func count(_ nodes: [PlaylistNode]) -> Int {
            nodes.reduce(0) { total, node in
                if node.resolvedIsFolder { return total + count(node.children ?? []) }
                return total + (Self.sameFile(current, node.url) ? 1 : 0)
            }
        }
        return count(settings.playlistItems)
    }

    /// 同一文件的判定：规范化后路径相同（与高亮判定保持一致）。
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func playCurrent() {
        guard let node = queue.current else { return }
        loadInto(node)
    }

    func playNext() {
        guard let node = queue.next() else {
            statusMessage = "已经是最后一个了"
            return
        }
        loadInto(node)
    }

    func playPrevious() {
        guard let node = queue.previous() else {
            statusMessage = "已经是第一个了"
            return
        }
        loadInto(node)
    }

    private func loadInto(_ node: PlaylistNode) {
        // 视图尚未挂上时也要能加载（见 ensureClient 的说明）
        guard let client = ensureClient() else { return }
        currentURL = node.url
        mediaTitle = node.name
        duration = 0
        setTimePos(0)
        isLoading = true
        loadChapterBook(for: node.url)
        client.loadFile(node.url)
        settings.recordRecent(node.url)
        lastSavedPosition = nil   // 新文件：让下一次落盘一定生效
        startHistoryTimer()
    }

    // MARK: - 播放控制

    func togglePlay() {
        client?.togglePause()
    }

    /// 确定性地设置播放/暂停（自检用，避免盲目 toggle 造成状态漂移）。
    func setPaused(_ paused: Bool) {
        client?.setPaused(paused)
    }

    func stop() {
        client?.stop()
        isPlaying = false
        setTimePos(0)
    }

    func seek(to seconds: Double) {
        client?.seek(to: seconds)
        // 立即把时钟推到目标位置：不等 mpv 的 time-pos 回调，
        // 否则点击进度条会有半拍延迟（进度条停在旧位置）。
        // mpv 真正的落点由随后的属性回调纠正。
        setTimePos(seconds)
    }

    func seek(by seconds: Double) {
        // 用属性回调里已经知道的播放位置换算成绝对位置：比同步读 mpv 的 time-pos 稳
        // （文件刚加载/暂停时同步读会 PROPERTY_UNAVAILABLE），也顺带夹在 [0, 时长] 内。
        let target = timePos + seconds
        let clamped = duration > 0 ? min(max(0, target), duration) : max(0, target)
        client?.seek(toAbsolute: clamped)
        setTimePos(clamped)
    }

    // MARK: - 窗口级输入（滚轮 / 中键，对整个窗口生效）

    /// 启动窗口级输入监听。滚轮与中键不再只绑定视频视图。
    func installGlobalInput() {
        let volume = NotificationCenter.default.addObserver(
            forName: .galeVolumeWheel, object: nil, queue: .main
        ) { [weak self] note in
            guard let delta = note.userInfo?["delta"] as? CGFloat else { return }
            self?.adjustVolume(by: delta)
        }
        let seek = NotificationCenter.default.addObserver(
            forName: .galeSeekWheel, object: nil, queue: .main
        ) { [weak self] note in
            guard let delta = note.userInfo?["delta"] as? CGFloat else { return }
            self?.seek(byWheel: delta)
        }
        globalInputObservers = [volume, seek]
    }

    func uninstallGlobalInput() {
        globalInputObservers.forEach(NotificationCenter.default.removeObserver)
        globalInputObservers = []
    }

    /// 统一拖放入口：**文件夹一律扫描整个文件夹**，不再因落点不同而行为不同。
    ///
    /// - Parameters:
    ///   - urls: 拖入的路径
    ///   - autoplay: 此前没有在播放时是否自动开始播放第一个
    @discardableResult
    func importDropped(_ urls: [URL], autoplay: Bool = true) -> Int {
        let files = urls.filter { !isDirectory($0) }
        let folders = urls.filter { isDirectory($0) }
        if !files.isEmpty { settings.addFiles(files) }
        for folder in folders { settings.addFolder(folder) }

        let added = files.count + folders.count
        if autoplay, currentURL == nil, let first = settings.orderedMedia.first {
            play(node: first, in: settings.orderedMedia)
        }
        return added
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func adjustVolume(by delta: Double) {
        volume = min(max(0, volume + delta), 200)
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = min(max(0.25, speed), 4)
        client?.setSpeed(currentSpeed)
        statusMessage = String(format: "播放速度 %.2gx", currentSpeed)
    }

    func changeSpeed(by delta: Double) {
        setSpeed(currentSpeed + delta)
    }

    func resetSpeed() {
        currentSpeed = 1
        client?.setSpeed(1)
        statusMessage = "恢复常速"
    }

    func screenshot() {
        guard let client else { return }
        let directory = settings.screenshotDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = (mediaTitle as NSString).deletingPathExtension
        let url = directory.appendingPathComponent("\(name)-\(formatter.string(from: Date())).png")
        client.screenshot(to: url.path)
        statusMessage = "截图已保存：\(url.lastPathComponent)"
    }

    func rotateClockwise() {
        videoRotation = (videoRotation + 90) % 360
        client?.setVideoRotate(videoRotation)
        toastRotation()
    }

    func rotateCounterclockwise() {
        videoRotation = (videoRotation + 270) % 360
        client?.setVideoRotate(videoRotation)
        toastRotation()
    }

    func toggleMirror() {
        isMirrored.toggle()
        client?.setMirror(isMirrored)
        showToast(isMirrored ? "已镜像" : "已取消镜像")
    }

    private func toastRotation() {
        switch videoRotation {
        case 90: showToast("旋转 90°（顺时针）")
        case 180: showToast("旋转 180°")
        case 270: showToast("旋转 270°（逆时针 90°）")
        default: showToast("画面已转正")
        }
    }

    // MARK: - 画面变换自检钩子

    /// 自检用：读回 mpv 当前的 `video-rotate`（命令是否送达）。
    func videoRotateForTesting() -> Double? {
        client?.getDouble("video-rotate")
    }

    /// 自检用：读回 mpv 当前的 `vf` 滤镜链。
    func vfForTesting() -> String? {
        client?.getString("vf")
    }

    /// 自检用：把当前帧截图到指定路径（验证滤镜是否真实作用于画面）。
    func screenshotForTesting(to path: String) {
        client?.screenshot(to: path)
    }

    /// 自检用：读回 mpv 当前实际生效的硬解模式（videotoolbox=零拷贝 / -copy=拷贝）。
    func hwdecForTesting() -> String? {
        client?.getString("hwdec-current")
    }

    func toggleFullScreen() {
        // 必须用**播放器窗口**，不能直接用 keyWindow：
        // 双击画面时若弹出过菜单/面板，keyWindow 可能已经变成别的窗口
        // （表现就是「双击没反应」）。
        // 直接在 PlayerCore 内挑窗口：排除 AppKit 内部窗口（如全屏转场遮罩），
        // 否则双击时 keyWindow 可能是那个内部窗口 → toggleFullScreen 无效。
        let target = NSApp.windows.first { win in
            win.isVisible
                && !String(describing: type(of: win)).hasPrefix("_NS")
                && !win.title.isEmpty
        } ?? NSApp.keyWindow
        target?.toggleFullScreen(nil)
    }

    /// 由 AppDelegate 在窗口全屏状态变化时回写（驱动 UI 切换全屏布局）。
    /// 幂等：值没变就不发 objectWillChange，避免轮询同步导致 SwiftUI 反复重算。
    func setFullScreen(_ value: Bool) {
        guard isFullScreen != value else { return }
        isFullScreen = value
    }

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
    }

    /// 统一的操作入口：菜单与按键监视器都走这里，避免两处行为漂移。
    func perform(_ action: HotKeyAction) {
        switch action {
        case .playPause: togglePlay()
        case .stop: stop()
        case .seekBackward: seek(by: Double(-seekStepSeconds))
        case .seekForward: seek(by: Double(seekStepSeconds))
        case .seekBackwardLong: seek(by: -60)
        case .seekForwardLong: seek(by: 60)
        case .previousMedia: playPrevious()
        case .nextMedia: playNext()
        case .speedUp: changeSpeed(by: 0.25)
        case .speedDown: changeSpeed(by: -0.25)
        case .speedReset: resetSpeed()
        case .volumeUp: adjustVolume(by: 5)
        case .volumeDown: adjustVolume(by: -5)
        case .mute: toggleMute()
        case .screenshot: screenshot()
        case .fullScreen: toggleFullScreen()
        case .alwaysOnTop: toggleAlwaysOnTop()
        case .rotateClockwise: rotateClockwise()
        case .rotateCounterclockwise: rotateCounterclockwise()
        case .mirror: toggleMirror()
        case .chapterAdd: addChapter()
        case .chapterDelete: deleteChapter()
        case .chapterPrevious: goToPreviousChapter()
        case .chapterNext: goToNextChapter()
        case .openFile, .openFolder: break   // 由菜单的文件面板处理
        case .newWindow:
            if !MultiInstance.spawn() {
                statusMessage = "最多同时打开 \(MultiInstance.maxInstances) 个窗口"
            }
        }
    }

    /// 当前快进/快退秒数（设置里可调 1–60）。
    var seekStepSeconds: Int { settings.seekStepSeconds }

    private func applyAlwaysOnTop() {
        NSApp.keyWindow?.level = isAlwaysOnTop ? .floating : .normal
    }

    // MARK: - 关键帧

    private func loadChapterBook(for url: URL) {
        let key = MediaKey.make(for: url)
        chapterBook = chapterStore.book(for: key)
            ?? ChapterBook(mediaKey: key, title: url.lastPathComponent)
    }

    var chapterTimes: [Int] { chapterBook?.times ?? [] }

    func addChapter() {
        guard var book = chapterBook else { return }
        guard book.add(at: timePos) != nil else {
            statusMessage = "该位置已有关键帧"
            return
        }
        commit(book)
        statusMessage = "已添加关键帧 \(String(format: "%@", format(timePos)))"
    }

    func deleteChapter() {
        guard var book = chapterBook else { return }
        guard let removed = book.removeNearest(before: timePos) else {
            statusMessage = "当前位置之前没有关键帧"
            return
        }
        commit(book)
        client?.seek(to: Double(removed))
        statusMessage = "已删除关键帧 \(format(Double(removed)))"
    }

    func removeAllChapters() {
        guard var book = chapterBook else { return }
        book.removeAll()
        commit(book)
        statusMessage = "已清空全部关键帧"
    }

    func goToNextChapter() {
        guard let book = chapterBook, let target = book.next(after: timePos) else {
            statusMessage = "后面没有关键帧了"
            return
        }
        client?.seek(to: Double(target))
        statusMessage = "跳到关键帧 \(format(Double(target)))"
    }

    func goToPreviousChapter() {
        guard let book = chapterBook, let target = book.previous(before: timePos) else {
            statusMessage = "前面没有关键帧了"
            return
        }
        client?.seek(to: Double(target))
        statusMessage = "跳到关键帧 \(format(Double(target)))"
    }

    func seek(toChapter seconds: Int) {
        client?.seek(to: Double(seconds))
        setTimePos(Double(seconds))
    }

    private func commit(_ book: ChapterBook) {
        chapterBook = book
        chapterStore.update(book)
    }

    /// A-B 循环：播放越过当前关键帧区间的终点时跳回起点（原 `repeat_chapter`）。
    private func enforceChapterLoop(at position: Double) {
        guard loopChapters,
              let range = chapterBook?.loopRange(at: position),
              position >= range.upperBound,
              Date().timeIntervalSince(lastLoopJump) > 0.25 else { return }
        lastLoopJump = Date()
        client?.seek(to: range.lowerBound)
    }

    // MARK: - 导入导出

    func exportChapters() {
        guard let book = chapterBook, !book.isEmpty else {
            statusMessage = "当前视频还没有关键帧"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\((currentURL?.lastPathComponent ?? "chapters")).chapters.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try book.exportData().write(to: url, options: .atomic)
            statusMessage = "关键帧已导出"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 导出播放列表（含每个文件的关键帧位置）。
    ///
    /// 入口：文件菜单 / 播放列表面板底部按钮。
    /// 格式按保存时选的文件名后缀决定：`.m3u8`（默认，任何播放器可开）或 `.json`（完整信息）。
    /// 导出用的统计数据（UI 提示与自检共用）。
    var playlistExportStatistics: (media: Int, withChapters: Int, chapters: Int, favorites: Int) {
        PlaylistExporter.statistics(items: settings.playlistItems, books: chapterStore.allBooks())
    }

    /// 生成导出内容（UI 的保存面板与自检走同一条路径，保证测的就是真路径）。
    func makePlaylistExport(format: PlaylistExportFormat) -> Data? {
        let items = settings.playlistItems
        guard !items.isEmpty else { return nil }
        let data = PlaylistExporter.export(
            items: items,
            books: chapterStore.allBooks(),
            format: format
        )
        return data.isEmpty ? nil : data
    }

    func exportPlaylist() {
        let items = settings.playlistItems
        guard !items.isEmpty else {
            statusMessage = "播放列表是空的"
            return
        }

        let books = chapterStore.allBooks()
        // 先按默认格式生成一次（含计数），面板上的统计与最终写入共用这一份结果，
        // 避免 statistics + export 各跑一遍 MediaKey（2000 项实测多花 ~100ms）。
        let preview = PlaylistExporter.exportWithCounts(items: items, books: books, format: .json)
        let stats = preview.counts

        let panel = NSSavePanel()
        panel.title = "导出播放列表"
        // 默认 Gale 原生格式（.json）：可由「导入播放列表」原样读回，
        // 文件夹层级、星标、关键帧位置都会带上。
        panel.nameFieldStringValue = "Gale 播放列表.json"
        panel.allowedContentTypes = [.json]
        panel.message = "共 \(stats.media) 项媒体，其中 \(stats.withChapters) 项带关键帧（"
            + "\(stats.chapters) 个位置）；层级、星标与关键帧都会写进文件，之后可再导入。"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format = PlaylistExportFormat.inferred(from: url)
        // 默认格式（.json）直接复用刚生成的结果；用户改成 .m3u8 才重新生成
        let data = format == .json
            ? preview.data
            : PlaylistExporter.exportWithCounts(items: items, books: books, format: format).data
        guard !data.isEmpty else {
            statusMessage = "导出失败：生成内容为空"
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            statusMessage = "已导出 \(stats.media) 项 / \(stats.chapters) 个关键帧 → \(url.lastPathComponent)"
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 播放进度记忆

    /// 每 3 秒把进度写进历史文件（退出前还会再写一次）。
    private func startHistoryTimer() {
        historyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.saveProgress() }
        }
        timer.resume()
        historyTimer = timer
    }

    private func stopHistoryTimer() {
        historyTimer?.cancel()
        historyTimer = nil
    }


    /// 把当前进度写进历史（定时 + 退出前都会调）。
    func saveProgress() {
        guard let url = currentURL, duration > 0, timePos > 0 else { return }
        // 暂停/停止时位置不变，重复写同一个值只是白白产生磁盘 I/O。
        // 注意用 `== nil ||`：**首次**（lastSavedPosition 为 nil）必须写，
        // 写成 `guard let last = ..., ... else { return }` 会让第一次直接返回。
        if let last = lastSavedPosition, abs(last.position - timePos) < 1 { return }
        history.record(url: url, position: timePos, duration: duration)
        history.save(to: historyURL)
        lastSavedPosition = (url, timePos)
    }

    private var lastSavedPosition: (url: URL, position: Double)?

    /// file-loaded 之后：若上次播到有意义的位置，就跳回去。
    private func applyResumePositionIfNeeded() {
        guard let url = currentURL else { return }
        // duration 属性可能还没回调，先用历史里记录的总时长兜底判断
        let totalDuration = duration > 0 ? duration : (history[url]?.duration ?? 0)
        guard totalDuration > 0 else { return }
        guard let position = history.resumablePosition(for: url),
              position < totalDuration - 5 else { return }
        client?.seek(to: position)
        showToast("已恢复上次进度 \(format(position))")
    }

    /// 进度记忆的落盘入口（退出前调用）：**无条件**写一次，
    /// 因为退出是最后的时机，这里不能因为「值没变」而丢掉本该保存的进度。
    func flushProgress() {
        guard let url = currentURL, duration > 0, timePos > 0 else { return }
        history.record(url: url, position: timePos, duration: duration)
        history.save(to: historyURL)
        lastSavedPosition = (url, timePos)
    }

    /// 供自检/排障：某个文件当前记录（或可恢复）的进度。
    func resumablePosition(for url: URL) -> Double? { history.resumablePosition(for: url) }

    /// 供自检：进度文件路径
    var playbackHistoryURL: URL? { historyURL }

    /// 供自检：丢弃内存副本、重新从磁盘读入（验证「真的落盘了」而不是内存残留）。
    func reseedHistoryFromDisk() {
        history = PlaybackHistory.load(from: historyURL)
    }
    func forgetProgress(for url: URL) {
        history.remove(url: url)
        history.save(to: historyURL)
    }

    // MARK: - 滚轮 / 中键

    /// 垂直滚轮（默认）：调音量。
    func adjustVolume(byWheel delta: Double) {
        let step = delta > 0 ? 5.0 : -5.0
        let target = min(max(volume + step, 0), 200)
        volume = target
        if isMuted && target > 0 { isMuted = false }
        showToast("音量 \(Int(target))%")
    }

    /// 横向滚轮 / ⇧+滚轮：跳进度，步长用设置里的「快进/快退秒数」。
    func seek(byWheel delta: Double) {
        guard duration > 0 else { return }
        let step = Double(seekStepSeconds) * (delta > 0 ? 1 : -1)
        let target = min(max(timePos + step, 0), duration)
        seek(to: target)
        showToast(target >= duration - 0.5 ? "已到片尾" : format(target))
    }

    /// 中键拖动：按纵向位移调音量（与滚轮同方向语义）。
    func adjustVolume(byMiddleDrag deltaY: CGFloat) {
        guard deltaY != 0 else { return }
        let percentPerPoint: CGFloat = 0.5
        let target = min(max(volume + Double(deltaY * percentPerPoint), 0), 200)
        volume = target
        showToast("音量 \(Int(target))%")
    }

    /// 短暂提示，1.2 秒后自动消失。
    func showToast(_ text: String) {
        toast = text
        toastToken += 1
        let token = toastToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }

    private var toastToken = 0

    /// 按**路径**写回一组关键帧（导入与自检共用）。
    ///
    /// 内部关键帧以 `MediaKey`（路径+大小+修改时间摘要）索引，而导入文件里保存的是路径，
    /// 所以要在这里换算。文件不在本机时无法算 MediaKey，返回 false。
    @discardableResult
    func restoreChapterBook(path: String, times: [Int]) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let mediaURL = URL(fileURLWithPath: path)
        let key = MediaKey.make(for: mediaURL)
        let existing = chapterStore.book(for: key)
        let title = (existing?.title.isEmpty == false ? existing!.title : mediaURL.lastPathComponent)
        var book = ChapterBook(mediaKey: key, title: title)
        for time in times.sorted() {
            book.add(at: Double(time))
        }
        chapterStore.update(book)
        return true
    }

    /// 导入播放列表（还原文件夹层级、星标与每个视频的关键帧）。
    ///
    /// 语义：**追加**到当前列表，不清空已有内容（避免误操作丢列表）；
    /// 重复导入同一个文件会产生重复项，这是有意为之的保守行为。
    /// 关键帧只对**本机确实存在**的文件还原（内部按 MediaKey 索引，需要文件的大小/时间）。
    func importPlaylist() {
        let panel = NSOpenPanel()
        panel.title = "导入播放列表"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "选择 Gale 导出的 .json 播放列表。导入为追加，不会清空当前列表。"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let result: PlaylistImportResult
        do {
            result = try PlaylistImporter.parse(contentsOf: url)
        } catch {
            statusMessage = "导入失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return
        }

        settings.addNodes(result.items)

        // 关键帧：路径 → MediaKey → ChapterStore（文件不在本机就跳过）
        var restored = 0, missing = 0
        for (path, times) in result.chaptersByPath {
            if restoreChapterBook(path: path, times: times) {
                restored += 1
            } else {
                missing += 1
            }
        }

        var message = "已导入 \(result.mediaCount) 项媒体"
        if restored > 0 { message += "，还原 \(restored) 项的关键帧（\(result.chapterCount) 个位置）" }
        if missing > 0 { message += "；\(missing) 项文件不在本机，关键帧跳过" }
        statusMessage = message
    }

    func importChapters() {
        guard let mediaURL = currentURL else {
            statusMessage = "请先打开一个视频"
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let book = try ChapterBook.importBook(from: data, mediaKey: MediaKey.make(for: mediaURL))
            commit(book)
            statusMessage = "关键帧已导入（\(book.count) 个）"
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "导入失败"
        }
    }

    // MARK: - 工具

    func format(_ seconds: Double) -> String {
        // 统一走 PlaybackClock.format，避免两处实现漂移
        // （章节时间是整数秒，四舍五入与截断结果一致）
        PlaybackClock.format(seconds)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}

/// 播放进度时钟。
///
/// 单独成一个极小的可观察对象，是为了把「每秒变几十次」的进度从 `PlayerCore`
/// 里隔离出去：SwiftUI 的 `@EnvironmentObject` 是「对象上任何 @Published 变化
/// 都让整个视图重算」，进度若挂在 PlayerCore 上，播放时会把整棵视图树
/// （含播放列表）一起重算。现在只有读 `clock.position` 的视图（进度条/时间文本）
/// 会重算，实测把这项开销从约 9 个百分点降到接近 0。
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0

    /// 显示用：把秒格式化成 mm:ss / h:mm:ss（全 App 唯一实现，供 PlayerCore 复用）
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
