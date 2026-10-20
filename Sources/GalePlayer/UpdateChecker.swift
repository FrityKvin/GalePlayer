import Foundation
import AppKit
import GaleCore

/// 更新检查器：从 GitHub Releases 拉最新版本、判断、提示。
///
/// 两个入口：
///   - 启动时自动检查（`autoCheckIfNeeded`，24 小时最多一次，失败静默）
///   - 菜单「检查更新…」（`checkManually`，失败提示）
///
/// 提示用系统弹窗（NSAlert）而不是 toast：更新这件事需要用户做决定，
/// toast 会自己消失、没有按钮。
@MainActor
final class UpdateChecker: ObservableObject {

    /// 单例：菜单和启动流程都要用，各自建实例会各自记时间戳。
    static let shared = UpdateChecker()

    /// 发布仓库。改动仓库地址只需要改这一处。
    /// 测试/开发时可用环境变量 GALE_UPDATE_REPO 覆盖（如指向有 release 的仓库）。
    nonisolated static var repository: String {
        if let override = ProcessInfo.processInfo.environment["GALE_UPDATE_REPO"],
           !override.isEmpty {
            return override
        }
        return "FrityKvin/GalePlayer"
    }

    /// 当前 App 版本（Info.plist 的 CFBundleShortVersionString）。
    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0"

    private let defaults = UserDefaults.standard

    private enum Key {
        static let lastCheck = "update.lastCheckAt"
        static let skipped = "update.skippedVersion"
        static let automatic = "update.automaticEnabled"
    }

    var automaticCheckEnabled: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.automatic) }
    }

    private var skippedVersion: String? {
        defaults.string(forKey: Key.skipped)
    }

    /// 自动检查间隔（24 小时）。
    private let autoCheckInterval: TimeInterval = 24 * 3600

    /// 进行中的检查（防连点）。
    private var inFlight = false

    // MARK: - 启动自动检查

    /// 启动后调用：满足间隔且开启自动检查才发请求；任何失败都不打扰用户。
    func autoCheckIfNeeded() {
        guard automaticCheckEnabled else { return }
        let last = defaults.double(forKey: Key.lastCheck)
        guard Date().timeIntervalSince1970 - last > autoCheckInterval else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let release = try? await self.fetchLatest() else { return }
            self.defaults.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
            self.presentIfNewer(release: release, automatic: true)
        }
    }

    // MARK: - 手动检查（菜单）

    func checkManually(core: PlayerCore) {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            defer { self?.inFlight = false }
            guard let self else { return }
            do {
                let release = try await self.fetchLatest()
                self.defaults.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
                switch UpdateCheck.decide(release: release,
                                          currentVersion: Self.currentVersion,
                                          skippedVersion: self.skippedVersion) {
                case .available(let version, _, _):
                    self.presentIfNewer(release: release, automatic: false)
                case .upToDate:
                    core.showToast("已是最新版本（\(Self.currentVersion)）")
                case .skipped(let version):
                    // 忽略过的版本手动检查时也要再提，给用户反悔的机会
                    self.presentUpdateAlert(release: release, skippedVersion: version)
                case .malformed:
                    core.showToast("版本信息格式异常，请到发布页查看")
                }
            } catch {
                core.showToast("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 网络

    private func fetchLatest() async throws -> UpdateCheck.GitHubRelease {
        try await UpdateAPI.fetchLatest()
    }

    // MARK: - UI

    private func presentIfNewer(release: UpdateCheck.GitHubRelease, automatic: Bool) {
        guard case .available = UpdateCheck.decide(
            release: release,
            currentVersion: Self.currentVersion,
            skippedVersion: skippedVersion) else { return }
        presentUpdateAlert(release: release, skippedVersion: nil)
    }

    private func presentUpdateAlert(release: UpdateCheck.GitHubRelease, skippedVersion: String?) {
        let decision = UpdateCheck.decide(release: release,
                                          currentVersion: Self.currentVersion,
                                          skippedVersion: skippedVersion)
        guard case .available(let version, let notes, let downloadURL) = decision else { return }

        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        alert.informativeText = notes ?? "到发布页查看更新内容。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "忽略此版本")
        alert.addButton(withTitle: "以后再说")

        // 弹窗会抢焦点；自动检查来的提示只在真有新版时弹（上面已保证）
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            defaults.set(version, forKey: Key.skipped)
        default:
            break
        }
    }
}

/// GitHub Releases 的网络层。
///
/// **必须是非隔离类型**：`--update-check` 自检在主线程上同步等信号量，
/// 如果拉取隔离在 MainActor（UpdateChecker 是 @MainActor 类），
/// 请求永远排不上主队列 → 死锁到超时（实测 20 秒）。网络请求本身
/// 不碰 UI 状态，放协作线程池完全安全。
enum UpdateAPI {

    /// GitHub 匿名限额只有 60 次/小时/IP：公共出口 IP（公司/校园 NAT）很容易被
    /// 别人用光。因此支持**可选**的令牌注入 —— 只从环境变量读
    /// `GALE_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN`，代码与仓库里不存任何密钥。
    static var optionalToken: String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["GALE_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"] {
            if let value = env[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// 自检/联调用：错误必须可区分（限额 vs 仓库不存在 vs 网络失败），
    /// 否则「仓库还没建」和「限额用光」会混成同一个报错。
    enum APIError: LocalizedError {
        case rateLimited
        case notFound
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                return "GitHub 接口限额用光（匿名 60 次/小时/IP），可设 GALE_GITHUB_TOKEN 或稍后再试"
            case .notFound:
                return "仓库不存在或尚无 Release"
            case .badStatus(let code):
                return "GitHub 接口返回 HTTP \(code)"
            }
        }
    }

    static func fetchLatest() async throws -> UpdateCheck.GitHubRelease {
        // https://api.github.com/repos/<owner>/<repo>/releases/latest
        let api = "https://api.github.com/repos/\(UpdateChecker.repository)/releases/latest"
        guard let url = URL(string: api) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // GitHub API 要求 UA；否则可能被拒
        request.setValue("GalePlayer/\(UpdateChecker.currentVersion)",
                         forHTTPHeaderField: "User-Agent")
        if let token = optionalToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 403, 429: throw APIError.rateLimited
            case 404: throw APIError.notFound
            default: throw APIError.badStatus(http.statusCode)
            }
        }
        return try JSONDecoder().decode(UpdateCheck.GitHubRelease.self, from: data)
    }
}
