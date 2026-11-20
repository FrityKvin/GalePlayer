import XCTest
@testable import GaleCore

/// 缺失文件判定（MissingFiles）的回归测试。
///
/// 背景：文件在磁盘上被删后，播放列表仍留着条目；播放器曾因此卡死
/// （无推进、无标记、无提示）。本组测试锁定「哪些路径算缺失」的纯逻辑。
final class MissingFilesTests: XCTestCase {

    /// 基本判定：注入的谓词说不存在的路径，进缺失集合。
    func testMissingPathsFromInjectedPredicate() {
        let existing: Set<String> = ["/tmp/ok1.mp4", "/tmp/ok2.mp4"]
        let paths = ["/tmp/ok1.mp4", "/tmp/gone.mp4", "/tmp/ok2.mp4", "/tmp/gone2.mkv"]

        let missing = MissingFiles.missing(in: paths) { existing.contains($0) }

        XCTAssertEqual(missing, ["/tmp/gone.mp4", "/tmp/gone2.mkv"],
                      "只有谓词判定不存在的路径才算缺失")
    }

    /// 空输入、全部存在 → 空集合。
    func testEmptyInputAndAllExisting() {
        XCTAssertTrue(MissingFiles.missing(in: []) { _ in false }.isEmpty,
                      "空列表必须得到空集合")

        let all = ["/tmp/a.mp4", "/tmp/b.mp4"]
        XCTAssertTrue(MissingFiles.missing(in: all) { _ in true }.isEmpty,
                      "全部存在时缺失集合必须为空")
    }

    /// 去重：同一路径重复出现只算一次。
    func testDuplicatesCollapseIntoOneEntry() {
        let missing = MissingFiles.missing(in: [
            "/tmp/gone.mp4", "/tmp/gone.mp4", "/tmp/gone.mp4",
        ]) { _ in false }

        XCTAssertEqual(missing, ["/tmp/gone.mp4"])
        XCTAssertEqual(missing.count, 1, "重复路径不得产生重复集合条目")
    }

    /// 从节点树取媒体路径（供 AppSettings 全表刷新用）。
    func testMediaPathsFromNodesFlattensFolders() {
        let folder = PlaylistNode(
            name: "剧",
            url: URL(fileURLWithPath: "/tmp/剧"),
            isFolder: true,
            children: [
                PlaylistNode(name: "01.mp4", url: URL(fileURLWithPath: "/tmp/剧/01.mp4"), isFolder: false),
                PlaylistNode(name: "02.mp4", url: URL(fileURLWithPath: "/tmp/剧/02.mp4"), isFolder: false),
            ]
        )
        let single = PlaylistNode(name: "外.mp4", url: URL(fileURLWithPath: "/tmp/外.mp4"), isFolder: false)

        let paths = MissingFiles.mediaPaths(from: [folder, single])

        XCTAssertEqual(paths.count, 3, "必须只取媒体文件路径（文件夹自身不算）")
        XCTAssertTrue(paths.contains("/tmp/剧/01.mp4"))
        XCTAssertTrue(paths.contains("/tmp/剧/02.mp4"))
        XCTAssertTrue(paths.contains("/tmp/外.mp4"))
        XCTAssertFalse(paths.contains("/tmp/剧"), "文件夹节点自身的路径不得进入媒体集合")
    }
}
