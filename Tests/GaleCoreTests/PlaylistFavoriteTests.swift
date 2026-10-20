import XCTest
@testable import GaleCore

/// 星标（收藏）与进度条几何的回归测试。
final class PlaylistFavoriteTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-fav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testFavoritePersistsAcrossReload() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = Playlist(directory: directory)
        playlist.add(files: [
            URL(fileURLWithPath: "/tmp/a.mkv"),
            URL(fileURLWithPath: "/tmp/b.mkv"),
        ])
        let target = playlist.orderedMedia[1]
        XCTAssertFalse(target.isFavorite)

        playlist.setFavorite([target.id], to: true)

        let reopened = Playlist(directory: directory)
        let starred = reopened.orderedMedia.first { $0.id == target.id }
        XCTAssertEqual(starred?.isFavorite, true, "星标必须落盘并在重开后保留")
        XCTAssertEqual(reopened.orderedMedia.first { $0.id != target.id }?.isFavorite, false)
    }

    func testToggleFavoriteFlipsOnlySelected() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = Playlist(directory: directory)
        playlist.add(files: [
            URL(fileURLWithPath: "/tmp/a.mkv"),
            URL(fileURLWithPath: "/tmp/b.mkv"),
        ])
        let both = Set(playlist.orderedMedia.map(\.id))
        XCTAssertEqual(playlist.orderedMedia.filter(\.isFavorite).count, 0)

        playlist.toggleFavorite(both)
        XCTAssertEqual(playlist.orderedMedia.filter(\.isFavorite).count, 2, "批量打星标")
        playlist.toggleFavorite(both)
        XCTAssertEqual(playlist.orderedMedia.filter(\.isFavorite).count, 0, "再翻一次应全部取消")
    }

    func testFavoriteOnFolderChildRecursively() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = Playlist(directory: directory)
        let folder = PlaylistNode(
            name: "剧集",
            url: URL(fileURLWithPath: "/tmp/剧集"),
            isFolder: true,
            children: [
                PlaylistNode(name: "第1集.mkv", url: URL(fileURLWithPath: "/tmp/剧集/第1集.mkv"), isFolder: false),
                PlaylistNode(name: "第2集.mkv", url: URL(fileURLWithPath: "/tmp/剧集/第2集.mkv"), isFolder: false),
            ]
        )
        playlist.add(nodes: [folder])

        let childID = try XCTUnwrap(playlist.items.first?.children?.last?.id)
        playlist.setFavorite([childID], to: true)

        let reopened = Playlist(directory: directory)
        XCTAssertEqual(reopened.items.first?.children?.last?.isFavorite, true, "嵌套子项也要能打星标")
        XCTAssertEqual(reopened.items.first?.children?.first?.isFavorite, false)
    }

    /// 老版本的 playlist.json 没有 isFavorite 字段，必须仍能读出来。
    func testLegacyJSONWithoutFavoriteFieldDecodes() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let legacy: [String: Any] = [
            "items": [[
                "id": id.uuidString,
                "name": "老版本.mkv",
                "url": "file:///tmp/老版本.mkv",
                "isFolder": false,
            ]],
            "recents": [],
            "clearOnExit": false,
            "clearOnOpen": false,
            "autoHideSeconds": 3,
            "imageMode": false,
        ]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: directory.appendingPathComponent("playlist.json"), options: .atomic)

        let playlist = Playlist(directory: directory)
        XCTAssertEqual(playlist.items.count, 1)
        XCTAssertEqual(playlist.items.first?.isFavorite, false)
    }
}

/// 进度条几何：关键帧标记位置必须与 time/duration 严格对应。
final class SeekBarGeometryTests: XCTestCase {

    func testMarkerXIsProportionalToTime() {
        // 100 秒的片子，30 秒处应落在 30% 处
        XCTAssertEqual(SeekBarGeometry.markerX(time: 30, duration: 100, width: 200, markerWidth: 2), 59, accuracy: 0.001)
        XCTAssertEqual(SeekBarGeometry.markerX(time: 0, duration: 100, width: 200, markerWidth: 2), 0, accuracy: 0.001)
        XCTAssertEqual(SeekBarGeometry.markerX(time: 100, duration: 100, width: 200, markerWidth: 2), 198, accuracy: 0.001)
    }

    func testMarkerXClampsOutOfRange() {
        XCTAssertEqual(SeekBarGeometry.markerX(time: -5, duration: 100, width: 200), 0, accuracy: 0.001)
        XCTAssertEqual(SeekBarGeometry.markerX(time: 500, duration: 100, width: 200), 198, accuracy: 0.001)
    }

    func testMarkerXHandlesUnknownDurationAndTinyBar() {
        XCTAssertEqual(SeekBarGeometry.markerX(time: 30, duration: 0, width: 200), 0)
        XCTAssertEqual(SeekBarGeometry.markerX(time: 30, duration: 100, width: 1), 0, "比标记还窄的轨道不能算出负偏移")
    }

    func testProgressWidthMatchesMarkerScale() {
        let width = SeekBarGeometry.progressWidth(position: 25, duration: 100, width: 400)
        XCTAssertEqual(width, 100, accuracy: 0.001)
        // 同一时刻：进度条末端应与关键帧标记中心重合
        let markerCenter = SeekBarGeometry.markerX(time: 25, duration: 100, width: 400, markerWidth: 2) + 1
        XCTAssertEqual(width, markerCenter, accuracy: 0.001)
    }

    func testTimeTextFormat() {
        XCTAssertEqual(SeekBarGeometry.timeText(0), "00:00")
        XCTAssertEqual(SeekBarGeometry.timeText(65), "01:05")
        XCTAssertEqual(SeekBarGeometry.timeText(3725), "1:02:05")
    }
}