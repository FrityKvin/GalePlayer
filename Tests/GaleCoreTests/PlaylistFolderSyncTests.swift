import XCTest
@testable import GaleCore

/// 重新拖入同一文件夹 = 就地同步（新增补进 / 消失移出 / 存活保 id+星标）。
///
/// 背景：Kevin 报的真实缺陷——文件夹加了新影片后再拖入播放列表，
/// `droppingDuplicates` 先按文件夹路径去重把整包新节点丢弃，
/// 新影片永远进不来；磁盘上删掉的影片也永远留在列表里（快照不更新）。
final class PlaylistFolderSyncTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-foldersync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 往目录里写一个假媒体文件（列表扫描只看扩展名，不打开文件）。
    private func writeMedia(_ dir: URL, _ name: String) throws {
        try "x".data(using: .utf8)!.write(to: dir.appendingPathComponent(name))
    }

    private func deleteMedia(_ dir: URL, _ name: String) throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// 场景一：文件夹新增影片后再拖入 → 新影片必须出现在列表里。
    func testReAddingSameFolderAppendsNewFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMedia(dir, "01.mp4")
        try writeMedia(dir, "02.mp4")

        let playlist = Playlist(directory: dir.appendingPathComponent("store"))
        playlist.add(folder: dir)
        XCTAssertEqual(playlist.orderedMedia.count, 2, "初次拖入应扫出 2 项")

        // 磁盘上加新片，再次拖入同一文件夹
        try writeMedia(dir, "03.mp4")
        playlist.add(folder: dir)

        XCTAssertEqual(playlist.orderedMedia.count, 3,
                       "再次拖入同一文件夹必须把新增影片同步进列表（现状是静默丢弃）")
        XCTAssertTrue(playlist.orderedMedia.contains { $0.name == "03.mp4" })
    }

    /// 场景二：磁盘上删掉影片后再拖入 → 死条目必须被移出列表。
    func testReAddingFolderDropsVanishedFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMedia(dir, "01.mp4")
        try writeMedia(dir, "02.mp4")

        let playlist = Playlist(directory: dir.appendingPathComponent("store"))
        playlist.add(folder: dir)

        try deleteMedia(dir, "02.mp4")
        playlist.add(folder: dir)

        XCTAssertEqual(playlist.orderedMedia.count, 1, "磁盘上删掉的影片不应继续留在列表里")
        XCTAssertTrue(playlist.orderedMedia.contains { $0.name == "01.mp4" })
        XCTAssertFalse(playlist.orderedMedia.contains { $0.name == "02.mp4" })
    }

    /// 场景三：存活的子项必须保留原节点（UUID 与星标不变），否则星标/选中态会丢。
    func testReAddingFolderKeepsChildIdentityAndStars() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMedia(dir, "01.mp4")
        try writeMedia(dir, "02.mp4")

        let playlist = Playlist(directory: dir.appendingPathComponent("store"))
        playlist.add(folder: dir)

        let before = playlist.orderedMedia
        let starred = before.first { $0.name == "01.mp4" }!
        playlist.setFavorite([starred.id], to: true)

        try writeMedia(dir, "03.mp4")
        playlist.add(folder: dir)

        let after = playlist.orderedMedia
        let survived = after.first { $0.name == "01.mp4" }
        XCTAssertEqual(survived?.id, starred.id, "存活子项必须保留原节点 id（星标/展开依赖它）")
        XCTAssertEqual(survived?.isFavorite, true, "星标必须在重新拖入后保留")
        XCTAssertEqual(after.first { $0.name == "03.mp4" }?.isFavorite, false, "新文件不带星标")
    }

    /// 场景四：不产生第二个 toggle，且原 toggle 的顶层 id 不变（展开状态依赖它）。
    func testReAddingFolderKeepsSingleToggleAndTopLevelID() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMedia(dir, "01.mp4")

        let playlist = Playlist(directory: dir.appendingPathComponent("store"))
        playlist.add(folder: dir)
        let firstToggleID = playlist.items[0].id
        let firstToggleName = playlist.items[0].name

        try writeMedia(dir, "02.mp4")
        playlist.add(folder: dir)

        XCTAssertEqual(playlist.items.count, 1, "重复拖入同一文件夹不得产生第二个 toggle")
        XCTAssertEqual(playlist.items[0].id, firstToggleID, "toggle 的顶层 id 必须稳定（展开状态）")
        XCTAssertEqual(playlist.items[0].name, firstToggleName)
        XCTAssertEqual(playlist.items[0].flattenedMedia.count, 2)
    }

    /// 场景五：新增子项按相对路径自然序插到正确位置（第5集 在 第4集 与 第6集 之间）。
    func testReAddedChildSortsNaturally() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMedia(dir, "第4集.mp4")
        try writeMedia(dir, "第10集.mp4")

        let playlist = Playlist(directory: dir.appendingPathComponent("store"))
        playlist.add(folder: dir)

        try writeMedia(dir, "第5集.mp4")
        playlist.add(folder: dir)

        let names = playlist.orderedMedia.map(\.name)
        XCTAssertEqual(names, ["第4集.mp4", "第5集.mp4", "第10集.mp4"],
                       "新文件必须按自然序插进正确位置（第5集 < 第10集）")
    }

    /// 回归钉：全新文件夹的子项全部以散文件形式已在列表 → 不产生空 toggle（原行为不变）。
    func testFreshFolderOfAllDuplicateLooseFilesStillDropped() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMedia(dir, "01.mp4")

        let playlist = Playlist(directory: dir.appendingPathComponent("store"))
        playlist.add(files: [dir.appendingPathComponent("01.mp4")])   // 先以散文件加入
        playlist.add(folder: dir)                                      // 再拖文件夹

        XCTAssertEqual(playlist.items.count, 1, "全部子项已存在（散文件形态）时不得新增空 toggle")
        XCTAssertFalse(playlist.items[0].resolvedIsFolder)
    }
}
