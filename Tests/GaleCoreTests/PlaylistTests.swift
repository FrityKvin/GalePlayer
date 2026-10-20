import XCTest
@testable import GaleCore

/// 播放列表测试，重点覆盖「剧集乱序」问题。
final class PlaylistTests: XCTestCase {
    func testNaturalSortOrdersEpisodesCorrectly() {
        let names = ["第10集.mp4", "第2集.mp4", "第1集.mp4"]
        let sorted = names.sorted { Playlist.naturalCompare($0, $1) }
        XCTAssertEqual(sorted, ["第1集.mp4", "第2集.mp4", "第10集.mp4"],
                       "自然序：第2集必须排在 第10集 之前（原版乱序是历史投诉点）")
    }

    func testNaturalSortHandlesNumericPrefixPadding() {
        let names = ["ep01.mkv", "ep2.mkv", "ep003.mkv"]
        let sorted = names.sorted { Playlist.naturalCompare($0, $1) }
        XCTAssertEqual(sorted, ["ep01.mkv", "ep2.mkv", "ep003.mkv"])
    }

    func testSupportedExtensionsCoverLegacyFormats() {
        for ext in ["rmvb", "rm", "avi", "wmv", "mkv", "mp4", "flv", "asf", "divx", "m2ts"] {
            XCTAssertTrue(MediaTypes.all.contains(ext), "\(ext) 应在原版支持清单内")
        }
        XCTAssertFalse(MediaTypes.all.contains("bhd"), "BHD 已决定不做")
    }

    func testSubtitleDetection() {
        XCTAssertTrue(MediaTypes.isSubtitle(URL(fileURLWithPath: "/tmp/a.ass")))
        XCTAssertTrue(MediaTypes.isSubtitle(URL(fileURLWithPath: "/tmp/a.SRT")))
        XCTAssertFalse(MediaTypes.isSubtitle(URL(fileURLWithPath: "/tmp/a.mp4")))
    }

    func testAddFilesFiltersUnsupportedAndSorts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let urls = [
            directory.appendingPathComponent("第10集.mp4"),
            directory.appendingPathComponent("note.txt"),
            directory.appendingPathComponent("第2集.rmvb"),
        ]
        for url in urls { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }

        let playlist = Playlist(directory: directory)
        playlist.add(files: urls)

        XCTAssertEqual(playlist.items.map(\.name), ["第2集.rmvb", "第10集.mp4"], "非媒体文件被过滤，媒体文件自然序")
    }

    func testFolderImportProducesSingleToggleWithFlatMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-flat-\(UUID().uuidString)")
        // 结构：root/S1/e2,e10,e1 + root/S2/S2-3/e5 + root/e0 + 空目录 + 非媒体文件
        let season1 = root.appendingPathComponent("S1")
        let season2 = root.appendingPathComponent("S2")
        let nested = season2.appendingPathComponent("S2-3")
        let empty = root.appendingPathComponent("Empty")
        for dir in [season1, nested, empty] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["e2.mkv", "e10.mkv", "e1.mkv"] {
            FileManager.default.createFile(atPath: season1.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        FileManager.default.createFile(atPath: nested.appendingPathComponent("e5.mkv").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("e0.avi").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("note.txt").path, contents: Data("x".utf8))

        let node = Playlist.folderNode(for: root)

        // 只有一个 toggle：根节点本身是文件夹，children 全是媒体文件（无嵌套文件夹节点）
        XCTAssertTrue(node.isFolder)
        XCTAssertEqual(node.children?.count, 5, "递归收集全部媒体文件（e0 + S1×3 + S2 深层×1）")
        XCTAssertTrue(node.children!.allSatisfy { !$0.isFolder }, "子项不得再出现文件夹节点（单层 toggle）")
        XCTAssertFalse(node.children!.contains { $0.name == "note.txt" }, "非媒体文件被过滤")

        // 相对路径自然序：e0 在前，S1/e1..e10 随后，S2/S2-3/e5 最后
        // （temporaryDirectory 是 /tmp → /private/tmp 符号链接，先归一化再裁前缀）
        let normalizedRoot = root.resolvingSymlinksInPath().path + "/"
        let paths = node.flattenedMedia.map {
            $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: normalizedRoot, with: "")
        }
        XCTAssertEqual(paths, ["e0.avi", "S1/e1.mkv", "S1/e2.mkv", "S1/e10.mkv", "S2/S2-3/e5.mkv"],
                       "按相对路径自然序：第2集在第10集前")
    }

    func testEmptyFolderImportYieldsChildlessToggle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-emptyflat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        FileManager.default.createFile(atPath: root.appendingPathComponent("readme.txt").path, contents: Data("x".utf8))
        let node = Playlist.folderNode(for: root)
        XCTAssertTrue(node.children?.isEmpty ?? true, "没有媒体文件时 children 为空")
        XCTAssertEqual(node.flattenedMedia.count, 0, "展开结果为空（不会误播非媒体文件）")
    }

    func testPlaylistPersistsAndClearsOnExit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-persist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = Playlist(directory: directory)
        playlist.add(files: [URL(fileURLWithPath: "/tmp/剧集01.mkv")])
        playlist.recordRecent(URL(fileURLWithPath: "/tmp/剧集01.mkv"))
        XCTAssertEqual(Playlist(directory: directory).items.count, 1, "列表应持久化")

        playlist.setClearOnExit(true)
        playlist.prepareForExit()
        XCTAssertTrue(playlist.items.isEmpty, "退出时清空生效")
        XCTAssertTrue(playlist.recents.isEmpty, "最近播放一并清空")
        XCTAssertTrue(Playlist(directory: directory).items.isEmpty, "清空结果已落盘")
    }

    func testClearOnOpenOnlyClearsWhenAdding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let playlist = Playlist(directory: directory)
        playlist.add(files: [URL(fileURLWithPath: "/tmp/a.mkv")])
        playlist.setClearOnOpen(true)
        playlist.add(files: [URL(fileURLWithPath: "/tmp/b.mkv")])
        XCTAssertEqual(playlist.items.map(\.name), ["b.mkv"], "打开时清空 → 只保留新加入的")

        playlist.setClearOnOpen(false)
        playlist.add(files: [URL(fileURLWithPath: "/tmp/c.mkv")])
        XCTAssertEqual(playlist.items.map(\.name), ["b.mkv", "c.mkv"], "关闭该选项后为追加")
    }

    func testLegacyNestedPlaylistIsFlattenedOnLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 模拟旧版本落盘的嵌套结构：root → [S1 → [e1], e0]，另有一个正常松散文件
        let media = { (name: String) -> [String: Any] in
            ["id": UUID().uuidString, "name": name, "url": "file:///tmp/\(name)", "isFolder": false]
        }
        let nested: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Root",
            "url": "file:///tmp/Root",
            "isFolder": true,
            "children": [
                [
                    "id": UUID().uuidString,
                    "name": "S1",
                    "url": "file:///tmp/Root/S1",
                    "isFolder": true,
                    "children": [media("e1.mkv")],
                ],
                media("e0.avi"),
            ],
        ]
        let storage: [String: Any] = [
            "items": [nested, media("loose.mp4")],
            "recents": [],
            "clearOnExit": false,
            "clearOnOpen": false,
            "autoHideSeconds": 3,
            "imageMode": false,
        ]
        try JSONSerialization.data(withJSONObject: storage)
            .write(to: directory.appendingPathComponent("playlist.json"), options: .atomic)

        let playlist = Playlist(directory: directory)

        XCTAssertEqual(playlist.items.count, 2, "顶层仍是「一个文件夹 toggle + 一个松散文件」")
        let folder = playlist.items[0]
        XCTAssertEqual(folder.children?.count, 2, "嵌套的 S1 被展开到同一层")
        XCTAssertTrue(folder.children!.allSatisfy { !$0.isFolder }, "不再保留文件夹节点")
        // 压平保留原有顺序（深度优先），不重排用户已有的列表
        XCTAssertEqual(folder.flattenedMedia.map(\.name), ["e1.mkv", "e0.avi"])

        // 归一化结果必须落盘，否则每次启动都要重算
        let reopened = Playlist(directory: directory)
        XCTAssertTrue(reopened.items[0].children!.allSatisfy { !$0.isFolder }, "压平结果已持久化")
    }

    func testQueueNavigationAndRemoval() {
        let a = PlaylistNode(name: "a", url: URL(fileURLWithPath: "/tmp/a.mkv"), isFolder: false)
        let b = PlaylistNode(name: "b", url: URL(fileURLWithPath: "/tmp/b.mkv"), isFolder: false)
        var queue = PlaybackQueue(items: [a, b])
        XCTAssertEqual(queue.current?.name, "a")
        XCTAssertEqual(queue.next()?.name, "b")
        XCTAssertFalse(queue.hasNext)
        XCTAssertEqual(queue.previous()?.name, "a")
        XCTAssertFalse(queue.hasPrevious)

        queue.remove([a.id])
        XCTAssertEqual(queue.current?.name, "b", "删除当前项后队列应落到可用项")
    }

    func testMediaKeyChangesWithFileContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("v.mkv")
        FileManager.default.createFile(atPath: file.path, contents: Data("short".utf8))
        let first = MediaKey.make(for: file)

        try Data("a much longer content".utf8).write(to: file)
        let second = MediaKey.make(for: file)

        XCTAssertNotEqual(first, second, "文件被替换后关键帧不应套用到新内容上")
        XCTAssertEqual(second, MediaKey.make(for: file), "同一文件重复计算结果稳定")
    }

    /// 重复加入同一文件不应产生多个节点 —— 否则按路径匹配的高亮会把副本一起点亮。
    func testAddingSameFileTwiceDoesNotDuplicate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-dedupe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.mp4")
        try Data([0]).write(to: file)

        let playlist = Playlist(directory: dir)
        playlist.add(files: [file])
        playlist.add(files: [file])

        XCTAssertEqual(playlist.items.count, 1, "同一文件重复添加后应只剩 1 项")
    }

    /// 导入同一份列表两次同样不应翻倍。
    func testAddingNodesTwiceDoesNotDuplicate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-dedupe2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mp4")
        let b = dir.appendingPathComponent("b.mkv")
        try Data([0]).write(to: a)
        try Data([0]).write(to: b)

        let playlist = Playlist(directory: dir)
        let nodes = Playlist.mediaNodes(from: [a, b])
        playlist.addNodes(nodes)
        playlist.addNodes(nodes)

        XCTAssertEqual(playlist.items.count, 2, "重复导入后应仍是 2 项")
    }

    /// 同一目录重复拖入不应出现第二个文件夹 toggle。
    func testAddingSameFolderTwiceDoesNotDuplicateToggle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-foldedup-\(UUID().uuidString)")
        let media = dir.appendingPathComponent("show")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0]).write(to: media.appendingPathComponent("ep01.mp4"))

        let playlist = Playlist(directory: dir)
        playlist.add(folder: media)
        playlist.add(folder: media)

        XCTAssertEqual(playlist.items.count, 1, "同一文件夹重复拖入应只剩 1 个 toggle")
        XCTAssertEqual(playlist.orderedMedia.count, 1, "媒体项不应翻倍")
    }
}
