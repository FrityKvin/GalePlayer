import AppKit
import Foundation
import GaleCore

/// 播放列表导出自检：走**真实数据源与真实导出代码**，把结果写到磁盘并回读校验。
///
/// 验证重点：导出的文件里必须带上每个视频的关键帧位置。
/// 用 `PlayerCore.makePlaylistExport` —— 与 UI 保存面板调用的是同一个函数，
/// 所以这里通过就等于真实导出通过（只有「弹保存面板」这一步没覆盖）。
///
/// 用法：GalePlayer --playlist-export-test <输出目录> <媒体文件>
enum PlaylistExportTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--playlist-export-test")
    }

    @MainActor
    static func start(core: PlayerCore?, settings: AppSettings?) {
        guard let core, let settings else {
            report("  失败：PlayerCore / AppSettings 未就绪")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            perform(core: core, settings: settings)
        }
    }

    // MARK: - 主体（后台线程）

    private static func perform(core: PlayerCore, settings: AppSettings) {
        var lines: [String] = ["播放列表导出自检"]

        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--playlist-export-test"),
              args.count > index + 2 else {
            report("用法: --playlist-export-test <输出目录> <媒体文件>")
            NSApp.terminate(nil)
            return
        }
        let outputDirectory = URL(fileURLWithPath: args[index + 1])
        let mediaURL = URL(fileURLWithPath: args[index + 2])
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 1. 造一个贴近真实用法的播放列表：一个文件夹（含 2 个媒体）+ 1 个散装媒体，
        //    并给其中一项加星标 —— 这样导出的样例包含文件夹标题、星标与关键帧三种信息。
        let tree = outputDirectory.appendingPathComponent("剧集 A")
        try? FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        for name in ["第1集.mp4", "第2集.mp4"] {
            let destination = tree.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: mediaURL, to: destination)
        }

        onMain {
            settings.clearPlaylist()
            settings.addFolder(tree)
            settings.addFiles([mediaURL])
        }
        spin(seconds: 0.5)

        // 给文件夹里的第一项加星标
        if let childID = onMain({ settings.playlistItems.first?.children?.first?.id }) {
            onMain { settings.setFavorite([childID], to: true) }
        }
        let stats = onMain { core.playlistExportStatistics }
        lines.append("  播放列表：媒体 \(stats.media) 项 · 星标 \(stats.favorites) 项 · 顶层 \(onMain { settings.playlistItems.count }) 项")

        // 2. 造两个关键帧（95s / 180s）—— 走真实的 seek + addChapter
        onMain { core.open(urls: [mediaURL]) }
        let loadDeadline = Date().addingTimeInterval(25)
        while onMain({ core.duration }) <= 0, Date() < loadDeadline {
            spin(seconds: 0.4)
        }
        guard onMain({ core.duration }) > 0 else {
            report((lines + ["  失败：媒体未加载"]).joined(separator: "\n"))
            NSApp.terminate(nil)
            return
        }
        // 逐点 seek 后等 timePos 真正更新再打点（自检环境 mpv 可能 idle，属性回调会慢）
        for target in [95.0, 180.0] {
            onMain { core.seek(to: target) }
            let deadline = Date().addingTimeInterval(4)
            while abs(onMain({ core.timePos }) - target) > 2, Date() < deadline {
                spin(seconds: 0.3)
            }
            onMain { core.addChapter() }
            spin(seconds: 0.3)
        }

        let chapterTimes = onMain { core.chapterTimes }
        lines.append("  已写入关键帧=\(chapterTimes)")

        // 3. 导出两种格式
        for format in PlaylistExportFormat.allCases {
            guard let data = onMain({ core.makePlaylistExport(format: format) }) else {
                lines.append("  失败：\(format.rawValue) 导出内容为空")
                continue
            }
            let url = outputDirectory.appendingPathComponent("export-test.\(format.fileExtension)")
            do {
                try data.write(to: url, options: .atomic)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                lines.append("  \(format.rawValue) → \(url.path)（\(size ?? 0) bytes）")
            } catch {
                lines.append("  失败：\(format.rawValue) 写入出错 \(error.localizedDescription)")
            }
        }

        // 4. 回读校验：文件里必须有关键帧位置
        // 不变式：导出文件里的关键帧 == 实际关键帧集合（顺序与时间码一致）
        let expectedLine = "#GALE-CHAPTERS:" + chapterTimes
            .map { PlaylistExporter.timecode($0) }
            .joined(separator: ",")
        let m3u8URL = outputDirectory.appendingPathComponent("export-test.m3u8")
        if let text = try? String(contentsOf: m3u8URL, encoding: .utf8) {
            let chapterLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("#GALE-CHAPTERS:") }
            lines.append("  M3U8 关键帧行=\(chapterLines.isEmpty ? "（缺失！）" : chapterLines.joined(separator: " | "))")
            let matches = chapterLines == [expectedLine]
            lines.append("  期望=\(expectedLine)")
            lines.append("  M3U8 校验：\(matches ? "与实际关键帧完全一致 ✓" : "不一致 ✗")")
        } else {
            lines.append("  失败：M3U8 回读失败")
        }

        let jsonURL = outputDirectory.appendingPathComponent("export-test.json")
        if let data = try? Data(contentsOf: jsonURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let counts = root["counts"] as? [String: Any] {
            let jsonChapters = counts["chapters"] as? Int ?? -1
            lines.append("  JSON 统计：媒体=\(counts["media"] ?? "?") 含关键帧=\(counts["withChapters"] ?? "?") 关键帧数=\(jsonChapters)")
            lines.append("  JSON 校验：\(jsonChapters == chapterTimes.count ? "关键帧数量一致 ✓" : "数量不一致 ✗")")
        } else {
            lines.append("  失败：JSON 回读失败")
        }

        // 5. 导入闭环：清空后把刚导出的文件读回来，验证层级/星标/关键帧都还原
        onMain { settings.clearPlaylist() }
        spin(seconds: 0.3)
        let emptyAfterClear = onMain { core.playlistExportStatistics.media }
        lines.append("  清空后媒体数=\(emptyAfterClear)")

        if let result = try? PlaylistImporter.parse(contentsOf: outputDirectory.appendingPathComponent("export-test.json")) {
            onMain {
                settings.addNodes(result.items)
                for (path, times) in result.chaptersByPath {
                    core.restoreChapterBook(path: path, times: times)
                }
            }
            spin(seconds: 0.6)
            let stats2 = onMain { core.playlistExportStatistics }
            lines.append("  导入后：媒体 \(stats2.media) 项 · 星标 \(stats2.favorites) 项 · 关键帧 \(stats2.chapters) 个（\(stats2.withChapters) 项）")
            let roundTripOK = stats2.media == result.mediaCount
                && stats2.chapters == result.chapterCount
                && stats2.favorites == result.items.reduce(0) { $0 + $1.flattenedMedia.filter(\.isFavorite).count }
            lines.append("  闭环校验：\(roundTripOK ? "导出→导入后媒体/星标/关键帧完全一致 ✓" : "不一致 ✗（导出 \(result.mediaCount)/\(result.chapterCount) vs 导入 \(stats2.media)/\(stats2.chapters)）")")

            // 二次导出，验证再导出的文件仍带关键帧
            if let second = onMain({ core.makePlaylistExport(format: .json) }) {
                let secondURL = outputDirectory.appendingPathComponent("export-test-roundtrip.json")
                try? second.write(to: secondURL, options: .atomic)
                let reparsed = try? PlaylistImporter.parse(contentsOf: secondURL)
                lines.append("  二次导出→再解析：关键帧数=\(reparsed?.chapterCount ?? -1)（应与导入后一致）")
            }
        } else {
            lines.append("  失败：导出文件无法被导入（闭环断了）")
        }

        // 6. 恢复：清掉测试造的数据
        onMain {
            core.removeAllChapters()
            settings.clearPlaylist()
        }

        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    // MARK: - 工具

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func spin(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}