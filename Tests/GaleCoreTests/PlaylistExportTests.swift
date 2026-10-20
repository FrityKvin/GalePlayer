import XCTest
@testable import GaleCore

/// 播放列表导出：M3U8 与 JSON 两种格式，重点是**关键帧位置必须写进文件**。
final class PlaylistExportTests: XCTestCase {

    /// 固定时间，避免导出时间影响断言。
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func media(_ name: String, path: String, favorite: Bool = false) -> PlaylistNode {
        PlaylistNode(
            name: name,
            url: URL(fileURLWithPath: path),
            isFolder: false,
            isFavorite: favorite
        )
    }

    /// 用真实存在的临时文件生成 mediaKey（MediaKey 会取文件大小/时间）。
    private func makeRealFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("gale".utf8).write(to: url)
        return url
    }

    func testM3U8IsStandardAndCarriesChapterPositions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeRealFile(in: directory, named: "第1集.mp4")
        let second = try makeRealFile(in: directory, named: "第2集.mp4")

        let items = [
            media("第1集.mp4", path: first.path, favorite: true),
            media("第2集.mp4", path: second.path),
        ]
        // 第1集有两个关键帧（95 秒 = 00:01:35，180 秒 = 00:03:00），第2集没有
        let books = [
            ChapterBook(mediaKey: MediaKey.make(for: first), title: "第1集.mp4", times: [95, 180]),
        ]

        let text = PlaylistExporter.m3u8(items: items, books: books, exportedAt: fixedDate)

        XCTAssertTrue(text.hasPrefix("#EXTM3U\n"), "必须是标准 M3U8 头")
        XCTAssertTrue(text.contains("#EXTINF:-1,第1集.mp4"), "标题用 EXTINF 携带")
        XCTAssertTrue(text.contains(first.path), "写绝对路径，播放器可直接打开")
        XCTAssertTrue(text.contains("#GALE-CHAPTERS:00:01:35,00:03:00"), "关键帧位置必须以时间码写进文件")
        XCTAssertTrue(text.contains("#GALE-FAVORITE:1"), "星标也要带出去")
        // 每项只出现一次 EXTINF
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:-1,").count - 1, 2)

        // 只有第1集有关键帧 / 星标：统计行应体现
        XCTAssertTrue(text.contains("媒体 2 项 · 含关键帧 1 项（共 2 个）· 星标 1 项"), "统计行：\(text)")
    }

    func testM3U8OmitsChapterLineForFilesWithoutChapters() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try makeRealFile(in: directory, named: "no-chapters.mkv")
        let text = PlaylistExporter.m3u8(
            items: [media("no-chapters.mkv", path: url.path)],
            books: [],
            exportedAt: fixedDate
        )
        XCTAssertFalse(
            text.components(separatedBy: "\n").contains { $0.hasPrefix("#GALE-CHAPTERS:") },
            "没有关键帧就不该写这一行（头部说明里出现的格式示例不算）"
        )
        XCTAssertFalse(
            text.components(separatedBy: "\n").contains { $0.hasPrefix("#GALE-FAVORITE:") }
        )
        XCTAssertTrue(text.contains(url.path))
    }

    func testM3U8FlattensFolderInPlaybackOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeRealFile(in: directory, named: "第2集.mp4")
        let second = try makeRealFile(in: directory, named: "第10集.mp4")

        let folder = PlaylistNode(
            name: "剧集 A",
            url: directory,
            isFolder: true,
            children: [
                media("第2集.mp4", path: first.path, favorite: true),
                media("第10集.mp4", path: second.path),
            ]
        )
        let text = PlaylistExporter.m3u8(items: [folder], books: [], exportedAt: fixedDate)

        XCTAssertTrue(text.contains("# 文件夹：剧集 A（2 项）"))
        let firstIndex = try XCTUnwrap(text.range(of: "第2集.mp4")?.lowerBound)
        let secondIndex = try XCTUnwrap(text.range(of: "第10集.mp4")?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex, "顺序必须与播放顺序一致")
    }

    func testEmptyPlaylistStillProducesValidFile() {
        let text = PlaylistExporter.m3u8(items: [], books: [], exportedAt: fixedDate)
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(text.contains("媒体 0 项"))
        XCTAssertFalse(text.contains("#EXTINF"))
    }

    func testJSONKeepsTreeFavoritesAndChapterSeconds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeRealFile(in: directory, named: "a.mp4")
        let second = try makeRealFile(in: directory, named: "b.mp4")

        let folder = PlaylistNode(
            name: "合集",
            url: directory,
            isFolder: true,
            children: [
                media("a.mp4", path: first.path, favorite: true),
                media("b.mp4", path: second.path),
            ]
        )
        let books = [
            ChapterBook(mediaKey: MediaKey.make(for: first), title: "a.mp4", times: [12, 3661]),
        ]

        let data = try PlaylistExporter.json(items: [folder], books: books, exportedAt: fixedDate)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["format"] as? String, "gale-player-playlist")
        XCTAssertEqual(root["version"] as? Int, 1)

        let counts = try XCTUnwrap(root["counts"] as? [String: Any])
        XCTAssertEqual(counts["media"] as? Int, 2)
        XCTAssertEqual(counts["withChapters"] as? Int, 1)
        XCTAssertEqual(counts["chapters"] as? Int, 2)
        XCTAssertEqual(counts["favorites"] as? Int, 1)

        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let children = try XCTUnwrap(items[0]["children"] as? [[String: Any]])
        XCTAssertEqual(items[0]["isFolder"] as? Bool, true)
        XCTAssertEqual(children[0]["isFavorite"] as? Bool, true)
        XCTAssertEqual(children[0]["chapters"] as? [Int], [12, 3661], "JSON 里保存原始秒数，便于再导入")
        XCTAssertNil(children[1]["chapters"], "无关键帧的项不写 chapters 字段")
    }

    func testTimecodeFormatting() {
        XCTAssertEqual(PlaylistExporter.timecode(0), "00:00:00")
        XCTAssertEqual(PlaylistExporter.timecode(61), "00:01:01")
        XCTAssertEqual(PlaylistExporter.timecode(3661), "01:01:01")
        XCTAssertEqual(PlaylistExporter.timecode(3725), "01:02:05")
        XCTAssertEqual(PlaylistExporter.timecode(-5), "00:00:00", "负数夹到 0")
    }

    func testFormatInferredFromExtension() {
        // 默认必须是 Gale 原生格式（保证导出→导入闭环），只有明确写 .m3u8 才走 M3U8
        XCTAssertEqual(PlaylistExportFormat.inferred(from: URL(fileURLWithPath: "/tmp/a.json")), .json)
        XCTAssertEqual(PlaylistExportFormat.inferred(from: URL(fileURLWithPath: "/tmp/a.m3u8")), .m3u8)
        XCTAssertEqual(PlaylistExportFormat.inferred(from: URL(fileURLWithPath: "/tmp/a")), .json)
        XCTAssertEqual(PlaylistExportFormat.inferred(from: URL(fileURLWithPath: "/tmp/a.m3u")), .json,
                       "只有 .m3u8 才是 M3U8，.m3u / 无后缀都走原生格式")
        XCTAssertEqual(PlaylistExportFormat.inferred(from: URL(fileURLWithPath: "/tmp/a.M3U8")), .m3u8,
                       "后缀大小写不敏感")
    }

    /// 关键帧的关联键与内部存储保持一致（路径+大小+时间摘要），
    /// 因此导出时即使 book 的顺序打乱也能对上。
    func testChapterAssociationIsOrderIndependent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeRealFile(in: directory, named: "x.mp4")
        let second = try makeRealFile(in: directory, named: "y.mp4")

        let items = [
            media("x.mp4", path: first.path),
            media("y.mp4", path: second.path),
        ]
        let books = [
            ChapterBook(mediaKey: MediaKey.make(for: second), title: "y", times: [7]),
            ChapterBook(mediaKey: MediaKey.make(for: first), title: "x", times: [3]),
        ]

        let text = PlaylistExporter.m3u8(items: items, books: books, exportedAt: fixedDate)
        let lines = text.components(separatedBy: "\n")
        // x.mp4 后面应跟着 00:00:03，y.mp4 后面跟 00:00:07
        let xIndex = try XCTUnwrap(lines.firstIndex { $0.hasSuffix("/x.mp4") })
        let yIndex = try XCTUnwrap(lines.firstIndex { $0.hasSuffix("/y.mp4") })
        XCTAssertEqual(lines[xIndex + 1], "#GALE-CHAPTERS:00:00:03")
        XCTAssertEqual(lines[yIndex + 1], "#GALE-CHAPTERS:00:00:07")
    }
}