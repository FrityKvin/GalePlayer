import Foundation
import GaleCore

/// 更新检查自检（`--update-check`）。
///
/// 真实打 GitHub API（`releases/latest`），走完整的
/// 「拉取 → 解码 → 比版本 → 出决策」链路，**不弹 UI、不写 UserDefaults**
/// （自检不能有副作用，否则结果不可复现）。
///
/// 仓库默认是发布仓库；自检/联调时用环境变量指到有 release 的仓库：
///
/// ```bash
/// GALE_UPDATE_REPO=mpv-io/mpv <app> --update-check
/// ```
///
/// 输出 JSON：repository / currentVersion / latestTag / decision / downloadURL / elapsedMs
enum UpdateCheckReport {

    /// 自检在非隔离上下文里等异步结果：Swift 6 不允许闭包里直接改
    /// 局部变量（数据竞争检查）。用 @unchecked Sendable 的盒子装结果，
    /// 可见性由 semaphore 的 happens-before 保证。
    private final class ResultBox: @unchecked Sendable {
        var decisionText = ""
        var latestTag = ""
        var downloadURL = ""
    }

    static func run() {
        let start = Date()
        let repo = UpdateChecker.repository
        let current = UpdateChecker.currentVersion

        // URLSession 的 async 接口要跑在 RunLoop 环境里：用同步等待包住
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task {
            do {
                let release = try await UpdateAPI.fetchLatest()
                box.latestTag = release.tagName
                let decision = UpdateCheck.decide(release: release,
                                                   currentVersion: current)
                switch decision {
                case .available(let version, _, let url):
                    box.decisionText = "available(\(version))"
                    box.downloadURL = url
                case .upToDate:
                    box.decisionText = "upToDate"
                case .skipped(let version):
                    box.decisionText = "skipped(\(version))"
                case .malformed:
                    box.decisionText = "malformed"
                }
            } catch {
                box.decisionText = "error(\(error.localizedDescription))"
            }
            semaphore.signal()
        }

        let rc = semaphore.wait(timeout: .now() + 20)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if rc == .timedOut {
            box.decisionText = "error(20 秒超时)"
        }

        var lines = [
            "repository: \(repo)",
            "currentVersion: \(current)",
            "latestTag: \(box.latestTag.isEmpty ? "(拉取失败或无 release)" : box.latestTag)",
            "decision: \(box.decisionText)",
        ]
        if !box.downloadURL.isEmpty {
            lines.append("downloadURL: \(box.downloadURL)")
        }
        lines.append("elapsedMs: \(elapsed)")
        lines.append("结论: " + conclusion(for: box.decisionText))
        print("=== 更新检查自检 ===")
        for line in lines { print("  " + line) }

        // 自检模式：干完就退
        exit(0)
    }

    private static func conclusion(for decision: String) -> String {
        if decision.hasPrefix("available") { return "链路正常，发现新版 ✓" }
        if decision == "upToDate" { return "链路正常，已是最新 ✓" }
        if decision.hasPrefix("skipped") { return "链路正常（当前忽略该版本）✓" }
        if decision.hasPrefix("error") {
            return "网络/接口失败 —— 若仓库尚无 release 则属预期 ✗"
        }
        return "响应格式异常 ✗"
    }
}
