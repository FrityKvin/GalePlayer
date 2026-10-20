import Foundation
import SwiftUI
import GaleCore

/// 应用设置与播放列表状态（对 `GaleCore.Playlist` 的 SwiftUI 封装）。
@MainActor
final class AppSettings: ObservableObject {
    let directory: URL
    private let playlist: Playlist
    private let defaults = UserDefaults.standard

    @Published private(set) var playlistItems: [PlaylistNode] = []
    @Published private(set) var recents: [URL] = []
    @Published var imageMode: Bool = false { didSet { playlist.imageMode = imageMode } }
    @Published var clearOnExit: Bool = false
    @Published var clearOnOpen: Bool = false
    @Published var restartOnEnd: Bool = false
    @Published var screenshotDirectory: URL

    /// 快进/快退秒数，可在设置里调 1–60 秒（对应暴风影音的快进时长设置）。
    @Published private(set) var seekStepSeconds: Int = 10

    /// 可选范围（UI 与写入都以此为准，避免落盘脏数据）。
    /// 纯常量，标记为 nonisolated 以便后台线程的自检也能读。
    nonisolated static let seekStepRange = 1...60

    private enum Key {
        static let clearOnExit = "clearOnExit"
        static let clearOnOpen = "clearOnOpen"
        static let screenshotDir = "screenshotDirectory"
        static let restartOnEnd = "restartOnEnd"
        static let seekStep = "seekStepSeconds"
    }

    init(directory: URL) {
        self.directory = directory
        self.playlist = Playlist(directory: directory)
        self.imageMode = playlist.imageMode
        self.clearOnExit = defaults.bool(forKey: Key.clearOnExit)
        self.clearOnOpen = defaults.bool(forKey: Key.clearOnOpen)
        self.restartOnEnd = defaults.bool(forKey: Key.restartOnEnd)
        // 落盘值可能被手改或来自旧版本，统一夹到合法区间
        let storedStep = defaults.integer(forKey: Key.seekStep)
        self.seekStepSeconds = Self.clampSeekStep(storedStep == 0 ? 10 : storedStep)

        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let saved = defaults.string(forKey: Key.screenshotDir)
        self.screenshotDirectory = saved.map { URL(fileURLWithPath: $0) } ?? pictures.appendingPathComponent("Gale")

        refresh()
    }

    func refresh() {
        playlistItems = playlist.items
        recents = playlist.recents
    }

    var orderedMedia: [PlaylistNode] { playlist.orderedMedia }

    func addFiles(_ urls: [URL]) {
        playlist.add(files: urls, clearExisting: clearOnOpen)
        refresh()
    }

    func addFolder(_ url: URL) {
        playlist.add(folder: url, clearExisting: clearOnOpen)
        refresh()
    }

    func remove(ids: Set<UUID>) {
        playlist.remove(ids: ids)
        refresh()
    }

    func clearPlaylist() {
        playlist.clear()
        refresh()
    }

    func clearRecents() {
        playlist.clearRecents()
        refresh()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        playlist.move(fromOffsets: fromOffsets, toOffset: toOffset)
        refresh()
    }

    func recordRecent(_ url: URL) {
        playlist.recordRecent(url)
        recents = playlist.recents
    }

    func setClearOnExit(_ value: Bool) {
        clearOnExit = value
        defaults.set(value, forKey: Key.clearOnExit)
    }

    func setClearOnOpen(_ value: Bool) {
        clearOnOpen = value
        defaults.set(value, forKey: Key.clearOnOpen)
    }

    func setRestartOnEnd(_ value: Bool) {
        restartOnEnd = value
        defaults.set(value, forKey: Key.restartOnEnd)
    }

    /// 设置快进/快退秒数，自动夹到 1–60。
    func setSeekStepSeconds(_ value: Int) {
        let clamped = Self.clampSeekStep(value)
        seekStepSeconds = clamped
        defaults.set(clamped, forKey: Key.seekStep)
    }

    nonisolated static func clampSeekStep(_ value: Int) -> Int {
        min(max(value, seekStepRange.lowerBound), seekStepRange.upperBound)
    }

    /// 导入用：追加节点树并刷新 UI。
    func addNodes(_ nodes: [PlaylistNode]) {
        playlist.addNodes(nodes)
        refresh()
    }

    /// 星标：写入播放列表并刷新 UI（排序不变）。
    func toggleFavorite(_ ids: Set<UUID>) {
        playlist.toggleFavorite(ids)
        refresh()
    }

    func setFavorite(_ ids: Set<UUID>, to value: Bool) {
        playlist.setFavorite(ids, to: value)
        refresh()
    }

    func setScreenshotDirectory(_ url: URL) {
        screenshotDirectory = url
        defaults.set(url.path, forKey: Key.screenshotDir)
    }

    func prepareForExit() {
        playlist.prepareForExit()
    }
}
