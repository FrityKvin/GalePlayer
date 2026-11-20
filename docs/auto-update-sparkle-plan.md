# 在线自动更新方案（Sparkle 2）— 设计备忘

> **状态：暂缓，未实施**（Kevin 2026-11-20 决定：自动更新这部分暂时不做，留待未来）
>
> **当前行为**：检查到新版本 → NSAlert「前往下载」→ 打开浏览器下载 DMG → 用户手动拖入 Applications 覆盖。
> 即「半自动」：能提醒、能跳转，但下载安装仍需人手。

---

## 为什么暂缓时的结论：这件事不能"顺手做"

实施前必须先解决两个硬约束，否则做出来会出事故：

1. **签名是 ad-hoc**：`codesign -dv` 显示 `Signature=adhoc`、`TeamIdentifier=not set`。
   没有 Apple Developer 证书、未公证。
2. **未公证 + 浏览器下载 = quarantine**：Gatekeeper 会拦。App 自己下载的文件可以不带
   `com.apple.quarantine`（这是自研方案唯一能绕的点），但**无法验证更新包真实性**。

这决定了「自己下载 DMG → 解压 → 替换运行中的 .app」这条路必须自带**独立于 Apple 证书的
更新包签名校验**，否则等于给用户开了个任意代码执行的口子。

---

## 方案选型（当时比较的三个）

| 方案 | 做法 | 优点 | 缺点 | 结论 |
|---|---|---|---|---|
| **A. Sparkle 2** | 引入 `sparkle-project/Sparkle`，用它的 updater | EdDSA 签名校验不依赖 Apple 证书；原子替换；失败回滚；进度 UI；Delta 更新；业界验证（HandBrake/1Password/Rectangle 等） | 加一个 SPM 依赖；`make_dist.sh` 要嵌 Sparkle.framework；要维护 appcast.xml + EdDSA 密钥 | **推荐** |
| B. 自研轻量更新器 | 复用 GitHub Release API，自己下载 DMG/挂载/提取/替换 | 零依赖、与现有 `UpdateCheck` 连续 | 替换运行中 .app 的权限/codesign/spctl/SIP 坑很多；出 bug 会「更新后打不开」；长期维护成本高 | 不推荐 |
| C. 改善手动流程 | 保持现状，把「前往下载」做成一键下载+自动打开 | 改动最小（~30min），零风险 | 仍有一步人工；收益小 | 可作过渡 |

**选 A 的理由**：它已经解决了全部关键问题（签名校验、原子替换、回滚、进度），且本项目
`make_dist.sh` 已有完整的「内嵌依赖 + 由内向外重签」流程，接入 Sparkle 框架嵌入是自然延伸。

---

## Sparkle 实施步骤（未来照此执行）

### 0. 先确认的前置决策

- [ ] **许可证**：Sparkle 是 MIT + 部分 BSD 条款。本项目 GPL-2.0-or-later，GPL 允许链接 MIT 库 → 兼容。
      需同步更新 `licenses/` 与 `THIRD-PARTY-NOTICES.md`（`Scripts/make_licenses.py` 现成）。
- [ ] **EdDSA 密钥存放**：Sparkle 要求一对 EdDSA 密钥（私钥签名更新包，公钥进 Info.plist）。
      **私钥绝不能进仓库/对话/日志**。建议放 1Password，或 `~/.gale-keys/` 并加 .gitignore。
- [ ] **appcast 托管**：GitHub Releases 附加 `appcast.xml` 资产（raw URL），或自己托管
      （GitHub Pages / Cloudflare Pages / 自有域名）。决定后写进文档。
- [ ] **保留还是替换自定义菜单**：Sparkle 自带「检查更新」UI，可与现有 `GaleCommands` 里的
      「检查更新…」共存或替换。

### 1. 引入依赖（约 30 min）

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
],
targets: [
    .executableTarget(
        name: "GalePlayer",
        dependencies: ["GaleCore", "CMPV", .product(name: "Sparkle", package: "Sparkle")]
    ),
]
```

`Scripts/Info.plist` 加：

```xml
<key>SUFeedURL</key>
<string>https://<appcast 地址></string>
<key>SUPublicEDKey</key>
<string><EdDSA 公钥 base64></string>
<key>SUEnableAutomaticChecks</key>
<true/>
```

### 2. 生成 EdDSA 密钥

Sparkle 自带 `generate_appcast` / `generate_keys` 工具（在 Sparkle 的 bin 目录）。

```bash
# 私钥进钥匙串（Sparkle 默认行为）；公钥写进 Info.plist 的 SUPublicEDKey
./bin/generate_keys
```

### 3. 让 `make_dist.sh` 同时产出签好名的 appcast.xml

现状（100 行脚本）：`swift build` → 组装 .app → `bundle_deps.py` 内嵌 50+ 库 → 由内向外 codesign → DMG。

要加的两步：

- 把 `Sparkle.framework` 嵌入 `Contents/Frameworks/` 并重签（复用现有 `bundle_deps.py` 思路）。
- DMG 做完后跑 `generate_appcast`（对 DMG 做 EdDSA 签名 + 生成/追加 appcast.xml）。

关键：**appcast 里每条 item 必须带 EdDSA 签名与长度**，否则 Sparkle 拒绝。

### 4. 代码接入

- 删除/替换 `Sources/GalePlayer/UpdateChecker.swift` 的 NSAlert 流程，改用
  `SPUStandardUpdaterController`。
- `Sources/GaleCore/UpdateCheck.swift`（版本比较纯逻辑，11 个单测）可保留作兜底或删除
  —— 若删，需同步删 `UpdateCheckTests`。
- 保留现有的「24 小时最多检查一次 + 失败静默 + 跳过此版本」语义（Sparkle 有等价配置）。

### 5. 验证（必须做，不能只看编译过）

- 本地造两个版本：当前 0.1.2 + 假 0.1.3，走完整链路：检查 → 下载 → 校验 → 替换 → 重启。
- 负向用例：**篡改 DMG 一个字节 → Sparkle 必须拒绝并报签名错误**（这是安全性的唯一证明）。
- 确认替换后 `codesign -dv` 有效、App 能启动、`playlist/chapters/history` 数据未丢
  （数据在 `~/Library/Application Support/`，替换 .app 不应影响；需实测确认）。
- 更新后重启会不会丢「正在播放进度」：现有 `applicationWillTerminate` 会 flush 进度，
  Sparkle 的 relaunch 路径要确认也走到了。

---

## 替代方案（若未来不想引依赖）

自研最小可行版本：`UpdateCheck` 已能拿到 DMG 的 `browser_download_url`，接着需要：

1. `URLSession` 下载到临时目录（App 自己下载 → 无 quarantine）
2. 校验：至少 SHA256 比对（更强的是 EdDSA，但需自己实现/引库）
3. `hdiutil attach` → 复制 `Gale Player.app` → `hdiutil detach`
4. 替换 `/Applications/Gale Player.app`（需处理「运行中」：先 `NSApp.terminate` 再延后替换）
5. 重新 `codesign --force --sign -`（ad-hoc）→ 启动新版本

**风险点**：第 4 步权限（/Applications 可能需用户授权）、第 5 步重签后 Gatekeeper 行为、
失败后的回滚。没有 EdDSA 就不该做全自动 —— 至少保留「用户确认」环节。

---

## 相关现有代码位置（未来从这里改）

| 文件 | 作用 |
|---|---|
| `Sources/GalePlayer/UpdateChecker.swift` | 检查/提示/NSAlert 三选（前往下载/忽略/以后再说），24h 节流，`GALE_UPDATE_REPO` 可覆盖仓库 |
| `Sources/GaleCore/UpdateCheck.swift` | 版本解析与比较、`decide()` 决策、DMG 资产挑选（多架构优先）—— 纯逻辑，11 个单测 |
| `Sources/GalePlayer/UpdateCheckReport.swift` | `--update-check` 自检，真实走 GitHub API |
| `Scripts/make_dist.sh` | 分发打包：内嵌依赖 → 重签 → DMG |
| `Scripts/Info.plist` | 需加 `SUFeedURL` / `SUPublicEDKey` |
| `Scripts/make_licenses.py` | 引入 Sparkle 后要补它的许可证 |

---

## 触发重新评估的信号

- 用户量变大、手动手动更新成了实际负担
- 拿到 Apple Developer 证书（可公证 → 更新体验能一步到位）
- 需要灰度/回滚能力
- 或 Kevin 明确要「不弹浏览器、App 内自己完成」

---

*本备忘由 engineerbot 于 2026-11-20 撰写，基于当日对现有升级链路的实际代码勘查。*
