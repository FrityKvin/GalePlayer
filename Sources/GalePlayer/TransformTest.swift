import AppKit
import Foundation
import GaleCore

/// 画面变换自检：旋转（顺/逆时针）与镜像是否真的写进了 mpv。
///
/// 验证两处：① PlayerCore 内部状态按预期变化；② mpv 侧属性/滤镜真的收到指令
/// （`video-rotate` 读回 90/180/270/0，`vf` 里出现/消失 `hflip`）。
/// 只证「命令送达」，不证「画面方向正确」——方向以 mpv 官方 menu.conf 为准
/// （video-rotate 正值 = 顺时针），已在 MPVClient 注释里写明依据。
///
/// 用法：GalePlayer --transform-test <媒体文件>
enum TransformTest {
    static func isRequested() -> Bool {
        CommandLine.arguments.contains("--transform-test")
    }

    @MainActor
    static func start(core: PlayerCore?) {
        guard let core else {
            print("  失败：PlayerCore 未就绪")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            perform(core: core)
        }
    }

    private static func perform(core: PlayerCore) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--transform-test"), args.count > i + 1 else {
            print("用法: --transform-test <媒体文件>")
            NSApp.terminate(nil)
            return
        }
        let url = URL(fileURLWithPath: args[i + 1])
        onMain { core.open(urls: [url]) }

        var lines: [String] = ["画面变换自检（旋转 / 镜像）"]

        // 等媒体加载
        let deadline = Date().addingTimeInterval(25)
        while onMain({ core.duration }) <= 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        lines.append("  媒体已加载=\(onMain { core.duration } > 0)")

        func check(_ name: String, _ ok: Bool) {
            lines.append("    \(name) \(ok ? "✓" : "✗")")
        }

        // ① 顺时针 → video-rotate 应为 90
        onMain { core.rotateClockwise() }
        Thread.sleep(forTimeInterval: 0.5)
        let afterCW = onMain { core.videoRotation }
        let mpvCW = onMain { core.videoRotateForTesting() }
        check("顺时针 → 状态 \(afterCW)（应 90）", afterCW == 90)
        check("顺时针 → mpv video-rotate=\(mpvCW ?? -999)（应 90）", mpvCW == 90)

        // ② 再顺时针 → 180
        onMain { core.rotateClockwise() }
        Thread.sleep(forTimeInterval: 0.3)
        let afterCW2 = onMain { core.videoRotation }
        check("再顺时针 → 状态 \(afterCW2)（应 180）", afterCW2 == 180)

        // ③ 逆时针 → 回到 90
        onMain { core.rotateCounterclockwise() }
        Thread.sleep(forTimeInterval: 0.3)
        let afterCCW = onMain { core.videoRotation }
        let mpvCCW = onMain { core.videoRotateForTesting() }
        check("逆时针 → 状态 \(afterCCW)（应 90）", afterCCW == 90)
        check("逆时针 → mpv video-rotate=\(mpvCCW ?? -999)（应 90）", mpvCCW == 90)

        // ④ 转回 0（逆时针 ×1）再验证
        onMain { core.rotateCounterclockwise() }
        Thread.sleep(forTimeInterval: 0.3)
        let backToZero = onMain { core.videoRotation }
        check("转回 → 状态 \(backToZero)（应 0）", backToZero == 0)

        // ⑤ 镜像开 → vf 含 hflip
        onMain { core.toggleMirror() }
        Thread.sleep(forTimeInterval: 0.4)
        let mirroredState = onMain { core.isMirrored }
        let vfOn = onMain { core.vfForTesting() } ?? ""
        check("镜像开 → 状态 \(mirroredState)（应 true）", mirroredState)
        check("镜像开 → vf 含 hflip（实际 \(vfOn)）", vfOn.contains("hflip"))

        // ⑥ 镜像关 → vf 不含 hflip
        onMain { core.toggleMirror() }
        Thread.sleep(forTimeInterval: 0.4)
        let vfOff = onMain { core.vfForTesting() } ?? ""
        let vfCleared = !vfOff.contains("hflip") && !vfOff.contains("format")
        check("镜像关 → 滤镜链已清空（实际 \(vfOff.isEmpty ? "空" : vfOff)）", vfCleared)

        // ⑦ 画面真实翻转验证：暂停 → 截图 → 开镜像 → 再截图，两图应不同
        onMain { core.setPaused(true) }
        Thread.sleep(forTimeInterval: 0.4)
        let hwdecBefore = onMain { core.hwdecForTesting() } ?? "?"
        onMain { core.screenshotForTesting(to: "/tmp/tt-mirror-a.png") }
        Thread.sleep(forTimeInterval: 0.6)
        onMain { core.toggleMirror() }
        Thread.sleep(forTimeInterval: 0.6)
        let hwdecAfter = onMain { core.hwdecForTesting() } ?? "?"
        onMain { core.screenshotForTesting(to: "/tmp/tt-mirror-b.png") }
        Thread.sleep(forTimeInterval: 0.6)
        let imgA = (try? Data(contentsOf: URL(fileURLWithPath: "/tmp/tt-mirror-a.png"))) ?? Data()
        let imgB = (try? Data(contentsOf: URL(fileURLWithPath: "/tmp/tt-mirror-b.png"))) ?? Data()
        let imagesDiffer = imgA.count > 0 && imgB.count > 0 && imgA != imgB
        check("镜像截图差异（\(imgA.count)/\(imgB.count)字节，不同=已真实翻转，相同=未生效）", imagesDiffer)
        // auto-safe 语义：解码器始终零拷贝（hwdec-current=videotoolbox），
        // 有软件滤镜时由 mpv 在滤镜链里自行下载帧（不切解码器），性能无回归。
        check("零拷贝解码保留：无滤镜 \(hwdecBefore) → 有滤镜 \(hwdecAfter)（应均 videotoolbox）",
              hwdecBefore == "videotoolbox" && hwdecAfter == "videotoolbox")

        let ok = afterCW == 90 && mpvCW == 90 && afterCW2 == 180
            && afterCCW == 90 && mpvCCW == 90 && backToZero == 0
            && mirroredState && vfOn.contains("hflip") && !vfOff.contains("hflip")
            && imagesDiffer
        lines.append("  结论：" + (ok ? "旋转/镜像命令全部送达 mpv 且画面真实生效 ✓" : "存在缺陷 ✗"))
        print(lines.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    private static func onMain<T: Sendable>(_ body: @escaping @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
