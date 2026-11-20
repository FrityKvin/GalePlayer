import AppKit
import Foundation
import GaleCore

/// 文件夹再拖入自检：同一路径的文件夹重复拖入必须「就地同步」磁盘现状。
///
/// 用法：GalePlayer --folder-resync-test
///
/// 要回答的问题（Kevin 报的真实缺陷）：
///   拖入一个文件夹（快照）→ 磁盘上加新片/删旧片 → 再拖同一文件夹，
///   旧实现整包去重 = 静默 no-op：新片进不来、死条目出不去、还可能出双 toggle。
/// 修复后的预期行为：
///   1. 新增影片出现在列表里（按相对路径自然序插对位置）
///   2. 磁盘上消失的影片移出列表
///   3. 存活子项 id / 星标不变
///   4. 始终只有一个 toggle，toggle id 不变
enum FolderResyncTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--folder-resync-test")
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

    private static func perform(core: PlayerCore, settings: AppSettings) {
        var lines: [String] = ["文件夹再拖入同步自检"]

        var failed: [String] = []
        var passedTotal = 0
        func check(_ ok: Bool, _ label: String) {
            if ok { passedTotal += 1; lines.append("  ✓ \(label)") } else { failed.append(label); lines.append("  ✗ \(label)") }
        }

        // 造一个临时文件夹场景：3 个真实可播文件（mpv 能加载出 duration）
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-resync-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            for name in ["01.mp4", "02.mp4"] {
                try Data([0x00]).write(to: scratch.appendingPathComponent(name))
            }
        } catch {
            report("  失败：无法创建测试目录：\(error)")
            NSApp.terminate(nil)
            return
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 用系统真转码器？不——用 ffmpeg 生成真媒体太重；这里用「扩展名即媒体」
        // 的列表扫描特性 + 播放链路不参与（本自检只验列表同步语义），
        // 文件内容不需要真的可解码。
        lines.append("  目录=\(scratch.lastPathComponent) 初始=2 个媒体")

        // 1) 初次拖入
        onMain { settings.clearPlaylist() }
        onMain { settings.addFolder(scratch) }
        let count1 = onMain { settings.orderedMedia.count }
        check(count1 == 2, "初次拖入扫出 2 项（实际 \(count1)）")

        // 星标一个子项，验证同步后不丢
        let child1 = onMain { settings.orderedMedia.first { $0.name == "01.mp4" } }
        if let child1 {
            onMain { settings.setFavorite([child1.id], to: true) }
        }
        let toggleID = onMain { settings.playlistItems.first?.id }

        // 2) 磁盘变化：+1 新片（按自然序应插在中间）、-1 删片
        do {
            try Data([0x00]).write(to: scratch.appendingPathComponent("01a.mp4"))
            try FileManager.default.removeItem(at: scratch.appendingPathComponent("02.mp4"))
        } catch {
            report("  失败：磁盘变更出错：\(error)")
            NSApp.terminate(nil)
            return
        }
        lines.append("  磁盘变更：+01a.mp4 / -02.mp4 → 磁盘现状应为 [01, 01a]")

        // 3) 再次拖入同一文件夹 → 必须同步
        onMain { settings.addFolder(scratch) }

        let names = onMain { settings.orderedMedia.map(\.name) }
        check(names == ["01.mp4", "01a.mp4"],
              "再拖入后列表 = 磁盘现状 [01.mp4, 01a.mp4]（实际 \(names)）")
        check(!names.contains("02.mp4"), "磁盘上删掉的 02.mp4 移出列表")

        let toggles = onMain { settings.playlistItems.filter(\.resolvedIsFolder).count }
        check(toggles == 1, "仍然只有一个 toggle（实际 \(toggles)）")
        check(onMain { settings.playlistItems.first?.id } == toggleID, "toggle id 不变（展开状态保留）")

        let survived = onMain { settings.orderedMedia.first { $0.name == "01.mp4" } }
        check(survived?.id == child1?.id, "存活子项 id 不变")
        check(survived?.isFavorite == true, "星标在再拖入后保留")

        // 4) 空文件夹：全部删光再拖 → toggle 保留但 children 清空（不出新 toggle、不崩）
        do {
            for name in ["01.mp4", "01a.mp4"] {
                try FileManager.default.removeItem(at: scratch.appendingPathComponent(name))
            }
        } catch {
            report("  失败：清空目录出错：\(error)")
            NSApp.terminate(nil)
            return
        }
        onMain { settings.addFolder(scratch) }
        let emptyCount = onMain { settings.orderedMedia.count }
        check(emptyCount == 0, "文件夹清空后再拖 → 列表子项清空（实际 \(emptyCount)）")
        let togglesAfterEmpty = onMain { settings.playlistItems.filter(\.resolvedIsFolder).count }
        check(togglesAfterEmpty == 1, "空文件夹后仍只有一个 toggle（实际 \(togglesAfterEmpty)）")

        // 汇总
        lines.append("")
        if failed.isEmpty {
            lines.append("结果：PASS（\(passedTotal) 项断言全过）")
        } else {
            lines.append("结果：FAIL —— \(failed.count) 项未过：\(failed.joined(separator: "；"))")
        }
        report(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// 与 HighlightTest 同款主线程跳板（后台线程驱动 + DispatchQueue.main.sync）。
    /// 注意不要嵌套调用 onMain（dispatch_sync 重入会 SIGTRAP，见 MissingFileTest 的坑）。
    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private static func report(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        fflush(stdout)
    }
}
