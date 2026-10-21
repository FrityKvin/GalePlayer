import AppKit
import Foundation
import GaleCore

/// 播放列表性能自检（`--perf-test <目录>`）。
///
/// 只**量**，先不改：把「长列表展开慢 / 导入导出卡顿」拆成可独立计时的阶段，
/// 每段跑多次取中位数，避免拿一次偶然值下结论。
///
/// 测量项：
///   1. 扫描文件夹 + 加入列表（含去重、自然序、落盘）
///   2. 重复加入同一文件夹（纯去重路径）
///   3. orderedMedia（每次视图求值都要重算的派生数组）
///   4. 导出 JSON（含逐项 MediaKey = stat + SHA256）
///   5. 导入解析
///   6. 每行高亮判定 isCurrent（视图里按「行 × 重绘次数」放大）
///   7. 落盘
enum PerfTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--perf-test")
    }

    static func run() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--perf-test"), args.count > i + 1 else {
            print("用法: --perf-test <目录>")
            exit(1)
        }
        let root = URL(fileURLWithPath: args[i + 1])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gale-perf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        func ms(_ block: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            block()
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        }
        func median(_ n: Int, _ block: () -> Void) -> Double {
            let samples = (0..<n).map { _ in ms(block) }.sorted()
            return samples[samples.count / 2]
        }

        print("=== 播放列表性能自检 ===")
        print("  数据源: \(root.path)")

        var playlist = Playlist(directory: tmp)
        var scanMS = 0.0
        var rescanMS = 0.0
        playlist = Playlist(directory: tmp)
        scanMS = ms { playlist.add(folder: root) }
        let items = playlist.items
        let mediaCount = items.flatMap(\.flattenedMedia).count
        print("  媒体项数: \(mediaCount)")
        print(String(format: "  ① 扫描+加入文件夹        %8.1f ms", scanMS))

        rescanMS = ms { playlist.add(folder: root) }
        print(String(format: "  ② 重复加入（去重路径）    %8.1f ms", rescanMS))

        let ordered = median(5) { _ = playlist.orderedMedia }
        print(String(format: "  ③ orderedMedia（单次）    %8.3f ms", ordered))

        // 导出：books 为空 vs 有 200 个关键帧
        let empty: [ChapterBook] = []
        let books: [ChapterBook] = items.flatMap(\.flattenedMedia).prefix(200).map {
            ChapterBook(mediaKey: MediaKey.make(for: $0.url), title: $0.name, times: [10, 60, 120])
        }
        let exportNoBooks = median(3) {
            _ = PlaylistExporter.export(items: items, books: empty, format: .json)
        }
        let exportWithBooks = median(3) {
            _ = PlaylistExporter.export(items: items, books: books, format: .json)
        }
        print(String(format: "  ④ 导出 JSON（无关键帧）    %8.1f ms", exportNoBooks))
        print(String(format: "  ④ 导出 JSON（200 关键帧）  %8.1f ms", exportWithBooks))

        let data = PlaylistExporter.export(items: items, books: books, format: .json)
        let importMS = median(3) { _ = try? PlaylistImporter.parse(data: data) }
        print(String(format: "  ⑤ 导入解析                %8.1f ms", importMS))

        // 每行高亮判定：视图里是「行数 × 重绘次数」
        let playing = items.flatMap(\.flattenedMedia).first?.url
        let playingPath = playing.map { Playlist.canonical($0).path }
        let rows = items.flatMap(\.flattenedMedia).prefix(1000)
        var hits = 0
        let perRowMS = ms {
            for node in rows where PlaylistRow.isCurrent(node, playingPath: playingPath) { hits += 1 }
        }
        print(String(format: "  ⑥ isCurrent ×1000 行      %8.1f ms  （命中 %d 行）", perRowMS, hits))

        // 拆分导出成本：MediaKey(stat+SHA256) vs JSON 编码
        let urls = items.flatMap(\.flattenedMedia).map(\.url)
        let mediaKeyMS = ms { for u in urls { _ = MediaKey.make(for: u) } }
        let encodeMS = ms {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            _ = try? enc.encode(items)
        }
        let encodePlainMS = ms {
            let enc = JSONEncoder()
            _ = try? enc.encode(items)
        }
        print(String(format: "  ④a MediaKey ×%d           %8.1f ms", urls.count, mediaKeyMS))
        print(String(format: "  ④b JSON 编码(美化+排序键)  %8.1f ms", encodeMS))
        print(String(format: "  ④c JSON 编码(紧凑)        %8.1f ms", encodePlainMS))

        let saveMS = median(3) { playlist.setFavorite([items.first!.id], to: true) }
        print(String(format: "  ⑦ 落盘（单次写 JSON）      %8.1f ms", saveMS))

        try? FileManager.default.removeItem(at: tmp)
        exit(0)
    }
}
