import XCTest
@testable import GaleCore

/// 导入：与导出配对的闭环验证（导出 → 导入 → 内容一致）。
final class PlaylistImportTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testExportThenImportRoundTripKeepsTreeFavoritesAndChapters() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 造两个真实文件（MediaKey 需要文件大小/时间）
        func makeFile(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("gale".utf8).write(to: url)
            return url
        }
        let first = try makeFile("第1集.mp4")
        let second = try makeFile("第2集.mp4")
        let loose = try makeFile("散装.mkv")

        let folder = PlaylistNode(
            name: "剧集 A",
            url: directory,
            isFolder: true,
            children: [
                PlaylistNode(name: first.lastPathComponent, url: first, isFolder: false, isFavorite: true),
                PlaylistNode(name: second.lastPathComponent, url: second, isFolder: false),
            ]
        )
        let items = [
            folder,
            PlaylistNode(name: loose.lastPathComponent, url: loose, isFolder: false),
        ]
        let books = [
            ChapterBook(mediaKey: MediaKey.make(for: first), title: first.lastPathComponent, times: [95, 180]),
            ChapterBook(mediaKey: MediaKey.make(for: second), title: second.lastPathComponent, times: [30]),
        ]

        // 导出 → 导入
        let data = PlaylistExporter.export(items: items, books: books, format: .json, exportedAt: fixedDate)
        let result = try PlaylistImporter.parse(data: data)

        // 列表结构
        XCTAssertEqual(result.items.count, 2, "顶层应还是 2 项（文件夹 + 散装）")
        XCTAssertTrue(result.items[0].resolvedIsFolder)
        XCTAssertEqual(result.items[0].children?.count, 2)
        XCTAssertEqual(result.items[0].children?.first?.isFavorite, true, "星标要还原")
        XCTAssertEqual(result.items[0].children?.last?.isFavorite, false)

        // 关键帧：按路径还原，值升序
        XCTAssertEqual(result.chaptersByPath[first.path], [95, 180])
        XCTAssertEqual(result.chaptersByPath[second.path], [30])
        XCTAssertNil(result.chaptersByPath[loose.path], "没关键帧的项不应出现条目")

        // 统计
        XCTAssertEqual(result.mediaCount, 3)
        XCTAssertEqual(result.chapterItemCount, 2)
        XCTAssertEqual(result.chapterCount, 3)
    }

    func testImportSortsChapterTimes() throws {
        let payload: [String: Any] = [
            "format": "gale-player-playlist",
            "version": 1,
            "exportedAt": "2026-10-19T00:00:00Z",
            "counts": ["media": 1, "withChapters": 1, "chapters": 3, "favorites": 0],
            "items": [[
                "name": "a.mkv",
                "path": "/tmp/a.mkv",
                "isFolder": false,
                "isFavorite": false,
                "chapters": [300, 10, 90],
            ]],
        ]
        let result = try PlaylistImporter.parse(
            data: try JSONSerialization.data(withJSONObject: payload)
        )
        XCTAssertEqual(result.chaptersByPath["/tmp/a.mkv"], [10, 90, 300], "读回来必须是升序")
    }

    func testImportRejectsForeignOrBrokenFiles() throws {
        // 不是本 App 的文件
        let foreign = try JSONSerialization.data(withJSONObject: ["format": "spotify-playlist", "items": []])
        XCTAssertThrowsError(try PlaylistImporter.parse(data: foreign)) { error in
            XCTAssertEqual((error as? PlaylistImportError)?.errorDescription,
                           PlaylistImportError.notGalePlaylist.errorDescription)
        }

        // 版本过新
        let future: [String: Any] = ["format": "gale-player-playlist", "version": 99, "items": []]
        XCTAssertThrowsError(
            try PlaylistImporter.parse(data: try JSONSerialization.data(withJSONObject: future))
        )

        // 完全不是 JSON
        XCTAssertThrowsError(try PlaylistImporter.parse(data: Data("这不是 JSON".utf8)))
    }

    func testImportToleratesMissingOptionalFields() throws {
        // 老文件可能没有 isFavorite / chapters
        let minimal: [String: Any] = [
            "format": "gale-player-playlist",
            "version": 1,
            "items": [["name": "a.mkv", "path": "/tmp/a.mkv", "isFolder": false]],
        ]
        let result = try PlaylistImporter.parse(
            data: try JSONSerialization.data(withJSONObject: minimal)
        )
        XCTAssertEqual(result.items.count, 1)
        XCTAssertFalse(result.items[0].isFavorite)
        XCTAssertTrue(result.chaptersByPath.isEmpty)
    }

    /// 导入的关键帧要能换算回内部索引用的 MediaKey（文件存在时）。
    func testImportedChaptersResolveToMediaKeys() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("x.mkv")
        try Data("gale".utf8).write(to: url)

        let payload: [String: Any] = [
            "format": "gale-player-playlist",
            "version": 1,
            "items": [[
                "name": "x.mkv", "path": url.path, "isFolder": false,
                "chapters": [12, 34, 56],
            ]],
        ]
        let result = try PlaylistImporter.parse(
            data: try JSONSerialization.data(withJSONObject: payload)
        )
        let times = try XCTUnwrap(result.chaptersByPath[url.path])

        // 模拟 PlayerCore 的写回逻辑：路径 → MediaKey → ChapterBook
        let key = MediaKey.make(for: url)
        var book = ChapterBook(mediaKey: key, title: url.lastPathComponent)
        book.removeAll()
        for time in times { book.add(at: Double(time)) }
        XCTAssertEqual(book.times, [12, 34, 56], "换算回 ChapterBook 后关键帧应一致")
        XCTAssertEqual(book.mediaKey, key)
    }

    /// 改名前的导出文件必须仍能导入 —— 老文件里的 format 是 "zephyr-playlist"。
    func testAcceptsLegacyZephyrFormatOnImport() throws {
        let legacy = """
        {
          "format": "zephyr-playlist",
          "version": 1,
          "items": [
            { "name": "第1集.mp4", "path": "/tmp/第1集.mp4", "isFavorite": false }
          ],
          "chapters": { "/tmp/第1集.mp4": [95] }
        }
        """
        let data = Data(legacy.utf8)
        let result = try PlaylistImporter.parse(data: data)
        XCTAssertEqual(result.items.count, 1, "改名前的导出文件必须仍能导入")
    }

    /// 新格式当然要能导入。
    func testAcceptsCurrentFormatOnImport() throws {
        let current = """
        {
          "format": "gale-player-playlist",
          "version": 1,
          "items": [
            { "name": "第1集.mp4", "path": "/tmp/第1集.mp4", "isFavorite": false }
          ]
        }
        """
        let result = try PlaylistImporter.parse(data: Data(current.utf8))
        XCTAssertEqual(result.items.count, 1)
    }
}
