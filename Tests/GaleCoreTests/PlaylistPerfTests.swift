import XCTest
@testable import GaleCore

/// 性能重构的行为锁：媒体计数、导出单次遍历的计数正确性。
final class PlaylistPerfTests: XCTestCase {

    private func media(_ name: String, path: String) -> PlaylistNode {
        PlaylistNode(name: name, url: URL(fileURLWithPath: path), isFolder: false)
    }

    private func folder(_ name: String, path: String, children: [PlaylistNode]) -> PlaylistNode {
        PlaylistNode(name: name, url: URL(fileURLWithPath: path), isFolder: true, children: children)
    }

    func testCountMedia() {
        // 1 个顶层文件 + 1 个文件夹（含 3 文件 + 嵌套文件夹含 2 文件）
        let tree = [
            media("a.mp4", path: "/tmp/a.mp4"),
            folder("D", path: "/tmp/D", children: [
                media("1.mp4", path: "/tmp/D/1.mp4"),
                media("2.mp4", path: "/tmp/D/2.mp4"),
                folder("E", path: "/tmp/D/E", children: [
                    media("3.mp4", path: "/tmp/D/E/3.mp4"),
                    media("4.mp4", path: "/tmp/D/E/4.mp4"),
                ]),
            ]),
        ]
        XCTAssertEqual(Playlist.countMedia(tree), 5)
    }

    func testCountMediaEmptyFolderIsZero() {
        // 空文件夹不产生媒体计数
        let tree = [folder("空", path: "/tmp/empty", children: [])]
        XCTAssertEqual(Playlist.countMedia(tree), 0)
    }

    func testJsonWithCountsSinglePass() throws {
        // 关键帧匹配：只给其中一个文件建关键帧
        let a = media("a.mp4", path: "/tmp/a.mp4")
        let b = media("b.mp4", path: "/tmp/b.mp4")
        let items = [folder("D", path: "/tmp/D", children: [a, b])]
        let books = [ChapterBook(mediaKey: MediaKey.make(for: b.url),
                                 title: "b", times: [10, 60, 120])]

        let result = try PlaylistExporter.jsonWithCounts(items: items, books: books)
        XCTAssertEqual(result.counts.media, 2)
        XCTAssertEqual(result.counts.withChapters, 1)
        XCTAssertEqual(result.counts.chapters, 3)
        XCTAssertEqual(result.counts.favorites, 0)

        // 解回 JSON 确认关键帧确实写进了对应的文件
        let payload = try JSONDecoder().decode(ExportedPlaylist.self, from: result.data)
        let chapters = payload.items[0].children?.compactMap { $0.chapters }.flatMap { $0 }
        XCTAssertEqual(chapters, [10, 60, 120])
    }

    func testJsonWithCountsNoBooksStillCounts() throws {
        let a = media("a.mp4", path: "/tmp/a.mp4")
        let b = media("b.mp4", path: "/tmp/b.mp4")
        let items = [a, b]
        let result = try PlaylistExporter.jsonWithCounts(items: items, books: [])
        XCTAssertEqual(result.counts.media, 2)
        XCTAssertEqual(result.counts.withChapters, 0)
        XCTAssertEqual(result.counts.chapters, 0)
    }
}

/// ExportedPlaylist 解码用（与 PlaylistExporter 内部结构一致的最小投影）。
private struct ExportedPlaylist: Decodable {
    struct Item: Decodable {
        let chapters: [Int]?
        let children: [Item]?
    }
    let items: [Item]
}
