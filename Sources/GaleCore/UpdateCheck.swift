import Foundation

/// 从 GitHub Releases 拉取版本更新的纯逻辑层（网络在 GalePlayer 里）。
///
/// 设计：拉 `https://api.github.com/repos/<owner>/<repo>/releases/latest`，
/// 比较 `tag_name` 与当前版本，发现新版就引导用户去下载 DMG。
///
/// 为什么不做「自动下载替换」：分发包是 ad-hoc 签名（未公证），浏览器下载的
/// 新 .app / DMG 会带 quarantine 标记，Gatekeeper 会拦、自动替换会失败；
/// 所以「提醒 + 跳转浏览器下载」才是与现状匹配的行为。
public enum UpdateCheck {

    // MARK: - GitHub API 的数据结构

    /// `GET /repos/<owner>/<repo>/releases/latest` 的响应（只取需要的字段）。
    public struct GitHubRelease: Decodable, Equatable {
        public let tagName: String
        public let name: String?
        public let htmlURL: String?
        public let body: String?
        public let assets: [Asset]

        public struct Asset: Decodable, Equatable {
            public let name: String
            public let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    // MARK: - 版本比较

    /// 解析 "v0.2.1" / "0.2.1" / "1.0" → [0, 2, 1]。
    /// 非数字部分（"-beta" 之类）忽略：预发布版本按数字前缀比较，够用。
    public static func versionNumbers(_ raw: String) -> [Int] {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
            .drop { $0 == "v" || $0 == "V" }
        let numbers = cleaned.prefix { $0.isNumber || $0 == "." }
        let parts = numbers.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? [0] : parts
    }

    /// 逐段数字比较：[0,2] > [0,1,9]；段数不同短的补 0（[1] == [1,0,0]）。
    public static func _compare(_ a: [Int], _ b: [Int]) -> Int {
        let count = max(a.count, b.count)
        for i in 0..<count {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    public static func isNewer(tag: String, than current: String) -> Bool {
        _compare(versionNumbers(tag), versionNumbers(current)) > 0
    }

    // MARK: - 决策

    public enum Decision: Equatable {
        /// 有新版；`downloadURL` 优先用 DMG 资产，没有就回退到 Release 页面。
        case available(version: String, notes: String?, downloadURL: String)
        /// 版本不比当前新。
        case upToDate
        /// 用户此前选择忽略这个版本。
        case skipped(version: String)
        /// 拉到了 release 但既没有 DMG 也没有页面地址（极端情况）。
        case malformed
    }

    /// 在 release 的资产里挑 DMG。多架构时优先包含当前架构名的那个。
    public static func preferredAsset(in release: GitHubRelease,
                                      arch: String = "") -> GitHubRelease.Asset? {
        let dmgs = release.assets.filter {
            $0.name.lowercased().hasSuffix(".dmg")
        }
        if dmgs.isEmpty { return nil }
        if !arch.isEmpty,
           let match = dmgs.first(where: { $0.name.lowercased().contains(arch.lowercased()) }) {
            return match
        }
        return dmgs.first
    }

    public static func decide(release: GitHubRelease,
                              currentVersion: String,
                              skippedVersion: String? = nil) -> Decision {
        let tag = release.tagName
        guard !tag.isEmpty else { return .malformed }
        if let skippedVersion, versionNumbers(tag) == versionNumbers(skippedVersion) {
            return .skipped(version: tag)
        }
        guard isNewer(tag: tag, than: currentVersion) else { return .upToDate }

        let notes = release.body.map { body in
            // Release notes 可能很长，UI 里只留摘要
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.prefix(12).joined(separator: "\n")
        }
        let download = preferredAsset(in: release)?.browserDownloadURL
            ?? release.htmlURL
            ?? ""
        guard !download.isEmpty else { return .malformed }
        return .available(version: tag, notes: notes, downloadURL: download)
    }
}
