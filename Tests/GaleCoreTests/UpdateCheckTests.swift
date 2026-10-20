import XCTest
@testable import GaleCore

/// 更新检查的纯逻辑：版本号解析、比较、发布决策（网络部分在 App 层，不在此测）。
final class UpdateCheckTests: XCTestCase {

    // MARK: - 版本号解析

    func testVersionNumbersParsesVariants() {
        XCTAssertEqual(UpdateCheck.versionNumbers("v0.2.1"), [0, 2, 1])
        XCTAssertEqual(UpdateCheck.versionNumbers("0.2.1"), [0, 2, 1])
        XCTAssertEqual(UpdateCheck.versionNumbers("V1.0"), [1, 0])
        XCTAssertEqual(UpdateCheck.versionNumbers("1"), [1])
        // 非数字尾巴截断
        XCTAssertEqual(UpdateCheck.versionNumbers("v0.3.0-beta.2"), [0, 3, 0])
        // 解析不出任何数字时不能返回空（后续比较要下标安全）
        XCTAssertEqual(UpdateCheck.versionNumbers("release"), [0])
    }

    // MARK: - 版本比较

    func testIsNewer() {
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v0.2.0", than: "0.1.9"))
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v1.0", than: "0.9.9"))
        // 段数不同：短版本补 0
        XCTAssertTrue(UpdateCheck.isNewer(tag: "v1", than: "0.99.99"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v1.0.0", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.1.0", than: "0.1.0"))
        // 同版带后缀不升级
        XCTAssertFalse(UpdateCheck.isNewer(tag: "v0.1.0-hotfix", than: "0.1.0"))
    }

    // MARK: - 资产挑选

    private func release(tag: String,
                         assets: [(String, String)] = [],
                         body: String? = nil,
                         html: String = "https://github.com/o/r/releases/tag/x") -> UpdateCheck.GitHubRelease {
        .init(tagName: tag,
              name: tag,
              htmlURL: html,
              body: body,
              assets: assets.map {
                  .init(name: $0.0, browserDownloadURL: $0.1)
              })
    }

    func testPreferredAssetPicksDMGAndCurrentArch() {
        let r = release(tag: "v0.2.0", assets: [
            ("Source code.zip", "https://x/zip"),
            ("Gale Player-0.2.0-arm64.dmg", "https://x/arm64.dmg"),
            ("Gale Player-0.2.0-x86_64.dmg", "https://x/x64.dmg"),
        ])
        XCTAssertEqual(UpdateCheck.preferredAsset(in: r, arch: "arm64")?
            .browserDownloadURL, "https://x/arm64.dmg")
        // 不带架构参数时取第一个 DMG
        XCTAssertEqual(UpdateCheck.preferredAsset(in: r)?.browserDownloadURL,
                       "https://x/arm64.dmg")
        // 没有 DMG 时回 nil
        XCTAssertNil(UpdateCheck.preferredAsset(in: release(tag: "v0.2.0")))
    }

    // MARK: - 决策

    func testDecideAvailable() {
        let r = release(tag: "v0.2.0",
                        assets: [("Gale Player-0.2.0-arm64.dmg", "https://x/dmg")],
                        body: "修复\n细节")
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.1.0"),
                       .available(version: "v0.2.0", notes: "修复\n细节",
                                  downloadURL: "https://x/dmg"))
    }

    func testDecideUpToDate() {
        let r = release(tag: "v0.1.0", assets: [("a.dmg", "https://x")])
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.1.0"), .upToDate)
        // 服务器上的版本更旧也视为最新
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.2.0"), .upToDate)
    }

    func testDecideSkippedVersion() {
        let r = release(tag: "v0.2.0", assets: [("a.dmg", "https://x")])
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.1.0",
                                          skippedVersion: "v0.2.0"),
                       .skipped(version: "v0.2.0"))
        // 忽略的旧版本不影响新版提醒
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.1.0",
                                          skippedVersion: "v0.1.9"),
                       .available(version: "v0.2.0", notes: nil,
                                  downloadURL: "https://x"))
    }

    func testDecideFallsBackToReleasePage() {
        // 没有 DMG 资产时回退到 Release 页面
        let r = release(tag: "v0.2.0", assets: [])
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.1.0"),
                       .available(version: "v0.2.0", notes: nil,
                                  downloadURL: "https://github.com/o/r/releases/tag/x"))
    }

    func testDecideMalformed() {
        // 空 tag、没有资产也没有页面 → malformed，不让 UI 拿到空 URL
        let r = release(tag: "", assets: [], html: "")
        XCTAssertEqual(UpdateCheck.decide(release: r, currentVersion: "0.1.0"), .malformed)
    }

    func testDecodesGitHubAPIResponse() throws {
        // 与真实 GitHub API 字段名对齐（tag_name / html_url / browser_download_url）
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "Gale Player 0.2.0",
          "html_url": "https://github.com/o/r/releases/tag/v0.2.0",
          "body": "更新说明",
          "assets": [
            { "name": "Gale Player-0.2.0-arm64.dmg",
              "browser_download_url": "https://x/dmg" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(UpdateCheck.GitHubRelease.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.tagName, "v0.2.0")
        XCTAssertEqual(decoded.assets.first?.browserDownloadURL, "https://x/dmg")
        XCTAssertEqual(UpdateCheck.decide(release: decoded, currentVersion: "0.1.0"),
                       .available(version: "v0.2.0", notes: "更新说明",
                                  downloadURL: "https://x/dmg"))
    }
}
