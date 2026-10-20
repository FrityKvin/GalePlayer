# Gale Player —— 基于暴风影音使用习惯 + libmpv 内核的 macOS 播放器

Apple Silicon 原生（arm64）的 macOS 视频播放器。工作代号 **Gale**（可改名，注意不能沿用「暴风影音」商标）。

## 目标与来源

| 项 | 来源 | 说明 |
|---|---|---|
| 播放能力（万能格式） | 暴风影音 Mac 1.1.6 的功能面 | 原版内核是静态链接的 FFmpeg 2.4；本项目建设在 libmpv（FFmpeg 9）上 |
| 播放列表管理 | 暴风影音 `BFPlayListTree` 等 164 个方法 | 树形文件夹、图文/文字双视图、拖拽排序、退出保存、最近播放；**拖入文件夹 = 单个 toggle，其下是递归扫出的扁平媒体列表**；**鼠标滑到视频区右缘浮出小箭头，点击弹出播放列表**（全屏下浮在画面之上） |
| 快捷键 | 暴风影音 `Resources/hotkey.plist` | 空格/⌘S/←→/⌘↑⌘↓/↩/⇧F5/⌘T/⌘O/⌘F 全部保留，**且可在设置里改绑** |
| 关键帧标记 | DMM Player v2「チャプター」体系 | 逆向移植：⌘A 添加 / ⌘D 删除 / ⌘N ⌘P 跳转 / 区间循环 / 导入导出 |
| ~~BHD 私有格式~~ | — | 已明确不做 |
| ~~P2P / 在线内容~~ | — | 原版服务端已停运，不复活 |

逆向依据：`../暴风影音复刻-逆向侦察报告.md`

## 环境要求

- macOS 14+（推荐 15+；libmpv 由 Homebrew 提供）
- Xcode 26+（含命令行工具）
- `brew install mpv meson ninja`
  - `mpv` 提供 `libmpv.dylib`（当前为 GPL 构建，见下方许可证）
  - `meson`/`ninja` 备用：将来切 LGPL 自建

```bash
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"
```

## 构建与运行

```bash
./Scripts/make_app.sh release     # 产物：build/Gale.app
open build/Gale.app             # 或 open -a build/Gale.app 某个视频.mp4
swift test                        # 36 个单元测试（关键帧算法 / 播放列表 / 快捷键绑定 / 持久化）
```

## 自检（回归验证）

### 解码链路

换 libmpv 版本（例如路线 A → B 切 LGPL 构建）后，用它验证解码链路：

```bash
BIN=build/Gale.app/Contents/MacOS/GalePlayer
"$BIN" --diagnose 影片.rmvb --shot /tmp/frame.png
```

输出解码器、分辨率、硬解状态、丢帧、窗口数（应为 1）与截图路径。实测结果：

| 格式 | 解码器 | 硬解 | 截图 |
|---|---|---|---|
| RMVB（RV40 + Cook） | RealVideo 4.0 / Cook | 无（老编码无硬解） | OK |
| HEVC 10bit | H.265/HEVC | `videotoolbox-copy`（p010） | OK |
| AV1 | AV1 | `videotoolbox-copy`（nv12） | OK |

### 窗口、全屏与布局

```bash
"$BIN" --window-report 影片.mp4
```

报告 `NSApp.windows`（确认只有一个窗口 —— 播放时不得另弹窗口）、
全屏进出（窗口是否覆盖整屏 / 是否退出全屏布局），
并在 720×460 → 2560×1400 七个尺寸间缩放检查布局跟随与 Auto Layout 冲突。

### 播放列表扫描

```bash
"$BIN" --list-folder /path/to/剧集目录
```

打印「单个 toggle + 扁平媒体列表」的扫描结果与播放顺序，
用于确认某目录为什么没被导入（扩展名不支持 / 权限 / 结构）。

### 视频视图生命周期（防 use-after-free 崩溃）

```bash
"$BIN" --lifecycle-test 影片.mp4
```

复现并防回归 incident 5693B60E：mpv 的 render 更新回调持有宿主视图指针，
视图被释放后回调仍在触发 → `objc_retain` 野指针 → 崩溃。
测试流程：起 mpv + 视图 → 播放（回调活跃）→ **停帧**后释放视图（不 detach）
→ 排空待执行 block → **恢复出帧**（回调打在刚释放的地址上）→ 检查存活。

> 关键：必须先停帧再释放。回调里的 `DispatchQueue.main.async { [self] }`
> 会强捕获视图，只要 mpv 还在出帧就总有待执行 block 吊着它，视图压根不析构，
> 野指针测不出来（这是第一版测试「假通过」的原因）。
> 把 `passRetained` 退回 `passUnretained` 可得到与线上崩溃报告完全一致的栈。

### 真实 UI 布局切换（端到端）

```bash
"$BIN" --ui-rebuild-test 影片.mp4
```

跑真实 SwiftUI 界面 + 真实 `PlayerCore`，直接驱动普通/全屏布局切换 4 轮，
检查每次切换后视频视图是否仍持有渲染上下文（拿不到 = `-20` 撞车 / 画面黑掉），
并验证全屏状态判定逻辑与窗口实际状态一致、可见窗口数为 1。

### 快捷键绑定

```bash
"$BIN" --hotkeys
```

打印当前生效键位表（含用户改绑标记）。

## 控制栏布局

```
[ 截图 · 静音 · 音量 ]      [ ⏮ ⏪ ▶ ⏩ ⏭ ⏹ ]      [ 关键帧 ±⏮⏭ ↻ | ⛶ ▤ ]
        居左                  严格居中                  居右
```

左右两组各自 `maxWidth: .infinity`，所以播放控制是真居中，不会被左侧图标数量带偏。

- 左侧：截图、静音、音量滑杆
- 中间：上一个 / 快退 10s / 播放暂停 / 快进 10s / 下一个 / 停止
- 右侧：关键帧 `+` `−` `⏮` `⏭` + 区间循环开关（+ 数量），分隔线，全屏，面板开关
- 已按用户反馈移除：书签图标（纯装饰、不可点）、窗口置顶按钮（功能保留在菜单 ⌘T）
- ⏪ ⏩ 的步长跟随设置（见下），⇧ 固定 60 秒

## 快进/快退秒数（1–60 秒）

设置 → 通用 → 播放 → 「快进 / 快退」。写入时自动夹到 `[1, 60]`，落盘存 `seekStepSeconds`。

作用范围：控制栏 ⏪ ⏩、菜单「快退/快进 N 秒」（标题随设置变）、← → 快捷键。
⇧← / ⇧→ 与 ⌘↑/⌘↓、上一/下一个视频这些固定语义不受影响。

## 按键通路（重要）

菜单自检（`--menu-test`）实测发现：**AppKit 菜单只对字母键真正注册键位**。
方向键、空格、回车、功能键挂上 `.keyboardShortcut` 后 `NSMenuItem.keyEquivalent`
是空字符串，而这些快捷键全工程没有 `keyDown` 兜底 —— 等于一半快捷键是死的。

现在的做法：

- `HotKeyMonitor` 用 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 接管所有按键，
  用 `KeyCombo.from(characters:keyCode:…)` 匹配用户绑定，再走 `PlayerCore.perform(_:)`
- 菜单只给「AppKit 认得的键」挂快捷键（`KeyCombo.isMenuRegistrable`），避免畸形项
- 不会重复触发：菜单键位在 `NSApplication.sendEvent` 阶段就被消费，事件到不了监视器
- ⌘Q 显式放行（退出永远由系统菜单处理）；文字输入框获得焦点时不拦截
- 特殊键的识别以 **keyCode 为兜底**（`KeyCombo.specialKey(forKeyCode:)`），
  因为 `characters` 对方向键/功能键经常为空

验证：`--input-test`（合成真实按键并检查播放状态/位置是否变化）。

## 播放列表悬浮入口

视频区右缘有一条 **20pt 宽的真实列**（不是 overlay），鼠标滑入即滑出小箭头
（`chevron.left` = 展开 / `chevron.right` = 收起），点击切换播放列表：

- 普通窗口：展开/收起右侧面板（并自动切到「播放列表」标签）
- 全屏：浮出贴右缘的材质播放列表（复用 `PlaylistPanel`），退出全屏时自动收起

面板已展开时箭头常驻，否则无法收起。

> ⚠️ **不能**用 `.overlay` 把这个标签叠在视频视图上：`MPVGLView` 是 `NSOpenGLView`，
> 它在 AppKit 命中测试里赢过 SwiftUI 浮层（实测视频右界内 6pt 处 `hitTest` 返回
> `MPVGLView`），鼠标移动事件被吃掉，`onHover` 永不触发 —— 症状就是「播放时箭头不出现」。
> 所以它必须是几何上不与 GL 视图重叠的兄弟节点。

## 检查更新（GitHub Releases）

更新源是本仓库的 GitHub Releases：

- **启动自动检查**：每天最多一次，失败静默（可在 设置 → 通用 → 更新 关闭）
- **手动检查**：应用菜单 → 检查更新…
- 发现新版弹窗（版本号 + 更新说明），三个选择：
  **前往下载**（打开 DMG 下载） / **忽略此版本** / **以后再说**
- 已忽略的版本手动检查时还会再提示（留反悔的机会）

实现：`GaleCore/UpdateCheck.swift`（版本解析/比较/决策，纯逻辑可单测）
+ `GalePlayer/UpdateChecker.swift`（网络与弹窗）。
拉 `https://api.github.com/repos/<owner>/<repo>/releases/latest`，
比较 `tag_name` 与 `CFBundleShortVersionString`，
下载地址优先选资产里**文件名含当前架构**的 DMG，没有 DMG 就回退到 Release 页面。

为什么不做「自动下载并替换」：分发包是 ad-hoc 签名（未公证），浏览器下载的
新 .app 带 quarantine 标记，Gatekeeper 会拦掉自动替换；「提醒 + 跳转浏览器」
才是与当前签名状态匹配的行为。

自检：`--update-check` 走完整链路（拉取 → 解码 → 比版本 → 出决策），
不弹 UI 不写 UserDefaults；仓库可用 `GALE_UPDATE_REPO` 指到别的仓库联调，
令牌可用 `GALE_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` 注入
（GitHub 匿名限额只有 60 次/小时/IP）。

发新版流程：

```bash
# 1. 改 Scripts/Info.plist 的版本号（CFBundleShortVersionString）
# 2. 出包
./Scripts/make_dist.sh release
# 3. 打 tag、推 tag、建 Release 并附上 DMG（gh release create 会自动识别 tag）
gh release create "v<版本>" "dist/Gale Player-<版本>-arm64.dmg" --title "Gale Player <版本>" --notes "更新说明"
```

Release 的 tag 必须是 `v` + 数字（`v0.2.0`），与应用内版本号保持一致。

## 名字：Gale Player

原名 Zephyr，2026-10 改为 **Gale Player**（bundle id `com.kevin.galeplayer`）。
取名沿用「风」的意象、承接暴风影音的使用习惯，但不与其商标冲突。

### 改名涉及的东西（改一处漏一处就会出问题）

| 项目 | 旧 | 新 |
|---|---|---|
| App 包名 | `Zephyr.app` | `Gale Player.app` |
| bundle id | `com.kevin.zephyr` | `com.kevin.galeplayer` |
| SwiftPM 目标 | `ZephyrPlayer` / `ZephyrCore` | `GalePlayer` / `GaleCore` |
| 数据目录 | `Application Support/com.kevin.zephyr/` | `.../com.kevin.galeplayer/` |
| UserDefaults | 域 = 旧 bundle id | 域 = 新 bundle id |
| 环境变量 | `ZEPHYR_*` | `GALE_*` |
| 队列/通知名 | `com.kevin.zephyr.*` | `com.kevin.galeplayer.*` |
| mpv 日志 | `/tmp/zephyr-mpv.log` | `/tmp/gale-mpv.log` |

### 数据迁移（`GaleMigration.swift`）

**改 bundle id 会静默丢两处数据**，`init()` 里第一件事就是迁移：

1. **文件**：`Application Support/<旧 id>/` 下的
   `playlist.json` / `chapters.json` / `playback-history.json` → 复制到新目录；
2. **UserDefaults**：设置项（`clearOnExit` / `clearOnOpen` / `restartOnEnd` /
   `seekStepSeconds` / `screenshotDirectory`）与快捷键覆盖
   （`zephyr.hotkeys.overrides` → `gale.hotkeys.overrides`）。
   因为 `UserDefaults.standard` 的实际落盘域就是 bundle id，换 id 等于换域。

设计上**只复制、不删旧目录**：用户数据不该由升级流程擅自删除。
确认新版没问题后可自行清理 `~/Library/Application Support/com.kevin.zephyr/`。

导出文件的兼容：新文件写 `"format": "gale-player-playlist"`，
但导入时**同时接受**旧的 `"zephyr-playlist"`，改名前的导出不会失效。

## 打包分发（不上架 App Store）

两条命令区分开：

| 脚本 | 用途 | 产物 |
|---|---|---|
| `Scripts/make_app.sh` | 本机开发 | `build/Gale Player.app`（**链接 Homebrew 的 libmpv，只有本机能跑**）|
| `Scripts/make_dist.sh` | 分发 | `dist/Gale Player-<版本>-arm64.dmg`（依赖全内嵌，任何 Mac 可用）|

### 为什么需要 make_dist.sh

`otool -L` 显示主二进制链的是 `/opt/homebrew/opt/mpv/lib/libmpv.2.dylib`。
完整依赖闭包 = **50 个非系统库 / 61.4 MB**（FFmpeg 9.0.2 全套、x264/x265/dav1d、
libplacebo/shaderc、openssl、libass/harfbuzz…）。没装 Homebrew mpv 的机器启动即 dyld 报错。

所以分发版必须：

1. 把闭包拷进 `Contents/Frameworks/`（`Scripts/bundle_deps.py`）
2. 每个库的 `LC_ID_DYLIB` 与依赖引用改写成 `@rpath/...`
3. 主二进制加 `LC_RPATH = @executable_path/../Frameworks`
4. **由内向外重新签名**（改过 install_name 的库签名必然失效，arm64 上无效签名会被内核直接杀掉）

### 自包含校验（`Scripts/verify_dist.py`）

出包前的硬门禁，任一项失败就中断出包：

- 包内每个 Mach-O 都不含 `/opt/homebrew`、`/usr/local/Cellar`、`/Users/...` 引用
- 主二进制引用的每个非系统库都在 `Contents/Frameworks/` 里
- `@executable_path/../Frameworks` 这条 rpath 存在
- `codesign --verify --deep --strict` 通过

实测输出：`内嵌库 50 个 / 60.9 MB，包内 Mach-O 51 个，零外部路径引用，签名有效`。

### 许可证（GPL 义务，不能省）

Homebrew 的 mpv 是 `GPL-2.0-or-later AND LGPL-2.1-or-later`，且链的是带 x264/x265 的
GPL 版 FFmpeg。把 dylib 打进包里分发 = 再分发 GPL 二进制，义务是附许可证全文 +
提供源码获取途径。`Scripts/make_licenses.py` 自动产出
`Contents/Resources/licenses/`（38 个组件、60 份许可证全文）+
`THIRD-PARTY-NOTICES.md`（逐库列出**版本 / 许可证 / 项目主页**）。

将来若要闭源或收费，必须切 LGPL 路线：自建 FFmpeg 加 `--disable-gpl`。
**播放器不需要 x264/x265 编码器，解码能力一点不损失。**

### 图标

`Scripts/make_icon.swift` 用 CoreGraphics 确定性生成（深靛蓝→青绿渐变 + 播放三角 + 风的流线），
产出 `Assets/GalePlayer.icns`（版本化）。图标缺失时 `make_dist.sh` 会自动生成。

### 签名与公证：两条路

**阶段 1（当前实现，0 成本）** — ad-hoc 签名。
用户首次打开需「右键 → 打开」一次，或：

```bash
xattr -dr com.apple.quarantine "/Applications/Gale Player.app"
```

`spctl -a -t install` 实测为 `rejected`，这是签名问题，与打包格式无关（DMG / ZIP / Cask 都一样）。

**阶段 2（$99/年 Apple 开发者账号）** — 改 `make_dist.sh` 里的 `SIGN_ID` 为
`Developer ID Application: <名字> (TEAMID)`，加 `--options runtime` 与 entitlements
（mpv 用 LuaJIT，可能需要 `com.apple.security.cs.allow-jit`），然后：

```bash
xcrun notarytool submit "dist/Gale Player-0.1.0-arm64.dmg" --apple-id <账号> --team-id <TEAM> --password <专用密码> --wait
xcrun stapler staple "dist/Gale Player-0.1.0-arm64.dmg"
```

之后用户双击即开，无任何提示。

### 架构

当前 **arm64-only**。Intel Mac 无法运行（Rosetta 方向相反），要支持需用 x86_64 的
mpv/FFmpeg 依赖做 universal 构建。

### 分发形态

- **DMG**（当前）— 拖进 Applications 的熟悉体验，`dist/` 下产出，30 MB
- ZIP — 内测用，**必须 `ditto -c -k --keepParent`**，普通 zip 会破坏 .app 内的符号链接
- Homebrew Cask — 需要公开 GitHub Release + 一个 tap

### 验证记录

打包版装到 `/Applications` 后实测：

- `--diagnose`：`status=loaded`、`libmpv=mpv v0.41.0`、`ffmpeg=9.0.2`、
  `H.264`、`hwdec=videotoolbox`、`960x540`、`duration=900`
- `DYLD_PRINT_LIBRARIES=1`：libmpv / libavcodec / libplacebo 全部从
  `.../Contents/Frameworks/` 加载，**从 Homebrew 加载 0 个**
- GUI 播放：1 个窗口，CPU 20–23%，内存 1.1%
- 卸载 DMG 后从 `/Applications` 重新启动仍正常（证明副本不依赖挂载卷）

## 资源占用

### 实测数据（Apple Silicon，真实 GUI 实例，`--resource-dump` 逐秒采样）

| 场景 | 优化前 | 优化后 |
|---|---|---|
| 720p H.264 播放 | 25.8% 单核 | **6.5%** |
| 4K H.264 播放 | 15.8%（拷贝型硬解） | **7.7%** |
| 1080p HEVC 10bit | — | 6.4% |
| 1080p AV1 | — | 5.5% |
| RMVB（软解，无硬解可用） | — | 5.6% |
| 暂停/空闲 | — | **0.17%** |
| 内存（720p 播放 / 暂停） | 220MB | 180MB / 113MB |

### 关键的三处改动

**1. 把播放进度从 `PlayerCore` 里拆出去（最大的一项，约 9 个百分点）**

`timePos` 原先挂在 `PlayerCore` 上且是 `@Published`。SwiftUI 里 `@EnvironmentObject`
的语义是「对象上**任何** `@Published` 变化都让用到该对象的整个视图重算」，
而进度每秒变几十次 —— 于是播放时 `ContentView` 每秒重算 24-36 次，
把播放列表、浮层、控制栏整棵树陪着重算。

现在进度走独立的 `PlaybackClock`，且进度条本身也拆成 `SeekBarView`
（只有它观察 clock）。结果：**ContentView 重算 = 0 次/秒**，
进度条仍有 24 次/秒的更新（比优化前更顺滑，因为不用再为了省 CPU 去节流）。

> 排查时做过对照实验：把节流放到 1 次/秒，CPU 从 13.6% 掉到 4.6% ——
> 这 9 个百分点全是白烧的视图重算，跟解码无关。

**2. 硬解改用零拷贝（4K 上省一半 CPU）**

`hwdec` 从 `auto-copy-safe`（拷贝型，帧要经系统内存中转）改成
`videotoolbox,auto-copy-safe`（优先零拷贝，不可用自动降级）。
4K H.264：CPU 15.8% → 8.6%，内存 470MB → 416MB。
1080p 及以下两者几乎无差别，所以这个改动只在播高分辨率时体现。

**3. 渲染后上报 swap**

`mpv_render_context_render` 之后补 `mpv_render_context_report_swap`。
不上报的话 mpv 只当渲染立刻完成，帧调度（vsync 之后下一帧的时机）会算错，
容易多画无用帧。

### 其他

- 进度文件只在位置真的变了才写（暂停时不写），避免无谓磁盘 I/O
- 缩略图缓存上限 120 条，防止图文模式下列表很长时无限增长
- mpv 解复用缓存限制到 32MiB（默认 150MiB，对本地文件是浪费）

### 怎么测

```bash
# 真实 GUI 实例逐秒采样（自检进程测不准，见下方说明）
launchctl setenv GALE_RESOURCE_DUMP /tmp/gale-res.jsonl
open -a build/Gale.app 视频.mp4 ; sleep 30
launchctl unsetenv GALE_RESOURCE_DUMP

# 环境变量开关（A/B 对比用）
launchctl setenv GALE_HWDEC videotoolbox     # 强制零拷贝
launchctl setenv GALE_PAUSE_AFTER 10         # 播 10 秒后自动暂停，测空闲开销
launchctl setenv GALE_HWDEC videotoolbox     # 强制零拷贝硬解（A/B 用）
```

逐秒采样里除了 CPU/内存/线程，还有：渲染占主线程的百分比、flush 阻塞时长、
**主线程响应延迟**（60Hz 自查定时器的实际触发延迟，超过 25ms 记一次卡顿）——
后者才是「UI 发不木」的客观指标。

> **为什么不用 `--resource-test` 的结果下结论**：自检进程不是交互应用，
> mpv 在里面**根本不推进播放**（实测「播放中」阶段 `time-pos` 推进 +0.0s），
> 测出来的 CPU 全是假的（甚至出现「播放比空闲还低」）。
> 可信数字必须来自 `open -a` 启动的正常实例。`--resource-test` 保留下来只作粗筛。

### 渲染不阻塞主线程（video-timing-offset）

播放时 UI 发木的根因不是 `flushBuffer`，而是 `mpv_render_context_render` 本身：
mpv 默认会「提前渲染一点，再阻塞等到该上屏的时刻」，**这个等待发生在调用方线程
（主线程）上**。`sample` 实测 12 秒窗口里主线程有 **4224 个样本**停在 libmpv 内部的
`_pthread_cond_wait`（约合墙钟 35%），而当时 flush 本身只占 0.1% —— 只看
`flushBuffer` 会得出完全错误的结论。

解决：**`video-timing-offset=0`**（一行配置）。

```
默认:  渲染提前量 X → mpv 阻塞等到目标时刻  →  主线程被堵
改后:  提前量 0      → 帧在该显示的时刻渲染   →  主线程不被堵
```

A/V 同步仍由 mpv 内部时序保证，不需要自己做补偿（mpv 文档明确
不建议手工等 `target_time`：实测那样会让画面卡在某个位置不动）。

| 指标 | 改之前 | 改之后 |
|---|---|---|
| 主线程渲染占用 | 0.49% | **0.06%** |
| 主线程卡顿 | 5.9 次/秒 | **0 次/秒** |
| 主线程最大延迟（均值） | 32ms | **5.7-10.6ms** |
| mpv 渲染路径上的阻塞样本 | 4224 / 12 秒 | **0** |

> 试过但**走不通**的路：把渲染搬到独立线程（CVDisplayLink + 离屏 FBO）。
> NSOpenGLView 的 drawable 与 GL 上下文都不是线程安全的，两次都崩在
> Metal/OpenGL 层（`GLDTextureRec::getTextureResource`、
> `IOGPU assert commit command buffer with uncommitted encoder`）。
> 要真正多线程渲染必须换掉整个 GL 宿主（自建 CGL 上下文 + 自管 drawable），
> 那是另一套架构，不值得为这点收益冒这个风险。

## ⚠️ 踩过的坑：`.allowsHitTesting(false)` 会让整块视频区失去交互

`VideoStage` 曾经被套了一层 `.allowsHitTesting(false)`（本意只是想让占位提示不挡事件，
写错了位置），结果**整个视频区收不到任何鼠标事件**：单击/双击/滚轮、
以及依赖点击的播放暂停与全屏**全部失效**。

已做 RED/GREEN 反证：

| | 命中视图 | 单击 | 双击全屏 |
|---|---|---|---|
| 有 `allowsHitTesting(false)` | `_NSSplitViewItemViewWrapper` | ✗ | ✗ |
| 去掉 | `MPVGLView` | ✓ | ✓ |

**规则**：`allowsHitTesting(false)` 只能加在**纯装饰**的叶子上
（如占位提示自己），绝不能加在包含 `NSViewRepresentable` 的容器上。

## ⚠️ 自检必须走真实事件派发链

`--mouse-test` 早期直接调 `view.mouseUp(event)`：这会**绕过 SwiftUI 的命中测试**，
所以上面那个 bug 测不出来（自检全绿、真机全废）。

现在改成 `window.sendEvent(event)`，走完整派发链，并且：
- 先把应用激活（`NSApp.activate` + `makeKeyAndOrderFront`）——
  **激活那一次点击会被系统吃掉**，不做这步第一个测试点击必然无效（假阴性）；
- 断言命中视图类型（视频区应为 `MPVGLView`，按钮应为 `SwiftUIAppKitButton`）；
- 点位只按**视频列**算（控制条不含右侧播放列表），且布局变化（进全屏）后要**重新测量**。

## 画面点击

| 操作 | 效果 |
|---|---|
| 单击画面 | 播放 / 暂停 |
| 双击画面 | 进入 / 退出全屏 |

实现要点：

- **双击防抖**：双击的第一次 `mouseUp`（clickCount == 1）必须延后 ~0.25s 再决定，
  否则双击会先触发一次「播放/暂停」再进全屏，表现为**双击后播放状态被反转**。
- **全屏目标窗口**：不能用 `NSApp.keyWindow`，要自己挑可见且非 AppKit 内部窗口
  （`_NS*`），否则双击时 keyWindow 可能是全屏转场遮罩，`toggleFullScreen` 无效。
- 进出全屏会**重建视频视图**，所以「再双击退出」必须重新查找视图，
  否则第二次点击打在已释放的旧视图上。

## 全屏下的播放列表右缘感应

普通窗口里箭头是一个 20pt 的**真实列**（不能是 overlay —— `MPVGLView` 会在
命中测试里赢过 SwiftUI 浮层，把 hover 吃掉）。全屏时那一列会让视频被挤窄，
所以改成 `isOverlayMode`：宽度 0，箭头用 overlay 贴到右缘。

显隐由 `EdgeRevealController` 驱动：
鼠标距右缘 ≤ 56pt 时显示箭头；播放列表已展开时，鼠标离开 > 140pt
延迟 0.45s 自动收起。

**用本地监听，不要用全局监听**：`addGlobalMonitorForEvents` 跟踪鼠标移动需要
「辅助功能」权限，没授权时**静默失效** —— 表现就是「鼠标贴到右缘但箭头永远不出现」。
本地监听（`addLocalMonitorForEvents`）不需要任何权限，全屏时鼠标本来就落在我们窗口上。
另外必须打开 `window.acceptsMouseMovedEvents = true`，否则 AppKit 不产生 `mouseMoved`。

控制器是 `ObservableObject`，SwiftUI 直接观察它 —— 不要再用定时器轮询状态。

## 验证

`--mouse-test <媒体文件>`：单击应切换播放状态、双击应进出全屏且**不反转播放状态**。

> 该自检直接向视图投递 `NSEvent.mouseEvent`，而不是用 CGEvent 合成：
> 非交互进程里合成事件打不进视图（实测「视图收到单击=0」，是 macOS 对
> CGEvent 的辅助功能权限限制），且从后台线程调全屏会抛
> `NSWindow geometry should only be modified on the main thread` 直接崩。
> 「真实鼠标能否送达视图」需在真机确认。

## 播放列表高亮当前播放项

正在播放的那一项会高亮：前置 `▶` 标记 + 标题变粗变主色 + 整行淡色底。
判定按路径 **resolvingSymlinksInPath + standardizedFileURL** 归一化后比较
（否则 `/tmp` 与 `/private/tmp` 会判成不同文件）。

因为判定是**按路径**而不是按节点 id，重复添加的同一文件会**整排一起高亮**。
所以 `Playlist.add(files:)` / `addNodes()`（导入）都会先按规范化路径去重：
同一文件重复添加、同一份列表导入两次，都不会再产生第二个节点。
文件夹节点则按「内部还有没有未出现过的媒体文件」决定保留还是丢弃。

**进入文件夹自动展开**：拖入文件夹后 toggle 默认是**折叠**的，子项根本没渲染，
高亮画在看不见的行上 —— 表现就是「不高亮」。现在 `currentURL` 落在某个文件夹内时
自动展开那个文件夹（`expandedFolders` + `DisclosureGroup(isExpanded:)`）。

**高亮必须逐节点判断，不能透传**：`PlaylistRow` 递归渲染子项时如果把父级的
`isCurrent` 直接传下去，父级是文件夹（恒为 false），**所有子项就永远不高亮**。
子项必须自己调 `PlaylistRow.isCurrent(_:playing:)`。
这是「文件夹内不高亮」的真正根因，判定自检发现不了（自检自己算路径匹配，
而 UI 用的是被透传错的值）。

**队列必须以播放列表为主体**：`open(urls:)` 早期把队列设成「本次打开的这些文件」，
于是用「打开方式 / 拖入」播一个文件后队列里只有它一个 → 点「下一个」没有下一项 →
`currentURL` 不变 → 高亮卡在第一项。现在队列 = 播放列表已有 + 本次新开的，
并定位到目标；**定位失败时不能回退到 0**（那会播成列表第一项，症状是「打开 A 播了 B」，
进度和高亮全记在 B 上）。

**验证**：`--highlight-test <媒体文件>...`、`--highlight-test --folder <目录>`、
`--folder-highlight-test <目录>`（最后这个走「点列表 → 点下一个」的完整真实路径）
（真实走 `play(node:in:)` → `orderedMedia` 队列）。
自检会**递归进文件夹子项**统计命中行数（与 `SidebarPanel` 的实际渲染一致），
并连点「下一个」验证高亮是否跟随 —— 期望恒为 1 行。
注意：统计必须递归，文件夹 toggle 下的子项同样是可见行；
只统计顶层节点会得出「0 命中」的假阴性。

## 滚轮与拖放：整个窗口生效

原先滚轮/中键绑在 `MPVGLView` 上（只在鼠标悬停画面时有效），
拖放则只有 `VideoStage` 的空状态占位接 `onDrop`（一旦播放就被画面盖住），
而且落点不同语义不同（拖到播放区只播单个文件、拖到列表才扫描文件夹）。

现在两者都上移到窗口层：

- `GlobalInputController` 用 `NSEvent.addLocalMonitorForEvents` 拦截
  `scrollWheel` / `otherMouse*`，按 `event.window` 过滤 → **窗口内任意位置**都生效；
  事件被消费后不会再下发给视图，所以 `MPVGLView` 里的旧处理已移除（否则会双触发）。
- `ContentView` 顶层挂 `onDrop` → `PlayerCore.importDropped(_:)`：
  **文件夹一律扫描整个文件夹**、文件加入列表，此前没在播则自动从第一个开始播。
  拖放悬停时整窗显示蓝色边框提示。

> 踩过的坑：`addLocalMonitorForEvents` 返回 `nil` 表示「不消费、继续传递」，
> 返回 `event` 才是不拦截。这里注释曾写反，导致事件被静默吞掉。

## 记住播放进度

对应暴风影音的「记住播放进度」，无需设置即生效：

- 播放中每 3 秒写一次，退出（⌘Q / 关闭窗口）时再写一次，存到
  `~/Library/Application Support/com.kevin.galeplayer/playback-history.json`
- 再次打开**同一个文件**时自动跳回上次位置，并弹一个「已恢复上次进度 mm:ss」的提示
- 只记「有意义」的进度，避免别扭的恢复：
  - 开头 10 秒内 → 不记（从头播更自然）
  - 播到距片尾 10 秒内 → 视为看完，**清掉**这条记录（下次从头开始）
  - 超过 30 天没再碰的条目 → 自动清理
- 退出时必须**先落盘进度再拆 mpv**（拆完就拿不到 `time-pos` / `duration` 了）

验证：`--resume-test <媒体文件> [秒]`（记录 → 落盘 → 重新读盘 → App 从磁盘重建）。

## 鼠标滚轮 / 中键

在视频画面上（普通与全屏都生效）：

| 操作 | 效果 |
|---|---|
| 纵向滚轮 | 调音量（每格 5%，自动取消静音） |
| 横向滚轮 / ⇧ + 纵向滚轮 | 跳进度，步长用设置里的「快进/快退秒数」 |
| 中键按住上下拖 | 调音量（每 1pt 移动 = 0.5%） |

每次操作都会在画面下方弹一个胶囊提示（音量百分比 / 目标时间），1.2 秒后自动消失。
小于 0.5 的滚动事件当作触控板噪声忽略。

## 导出 / 导入播放列表

**导出**（文件菜单 →「导出播放列表…」 ⌘⇧E，或播放列表面板底部的 ↥ 按钮）
默认导出 **Gale 原生 `.json`**，可由本播放器原样读回，用于备份、换机、分享。
保存面板里写文件名时改成 `.m3u8` 后缀则导出标准 M3U8 纯列表（关键帧与星标以
`#GALE-` 注释行携带）。

导出的 JSON 保留三样东西：

| 内容 | 说明 |
|---|---|
| 文件夹层级 | 完整 `PlaylistNode` 树，播放顺序不变 |
| 星标 | `isFavorite` |
| **关键帧位置** | 每个视频一个 `chapters: [秒…]`（整数秒、升序） |

**导入**（文件菜单 →「导入播放列表…」 ⌘⇧I，或面板底部 ↧ 按钮）
读回上面这种文件，还原层级、星标与关键帧。语义与边界：

- **追加**到当前列表，不清空已有内容（避免误操作丢列表）
- 重复导入同一文件会产生重复项（有意保持保守，不做自动去重）
- 关键帧只对**本机确实存在**的文件还原 —— 内部按 `MediaKey`（路径+大小+修改时间摘要）
  索引，文件不在就跳过了，状态提示里会说明跳过了几项
- 非本 App 导出的文件、版本过新、文件损坏都会给出对应的错误提示，不会静默失败

验证：`--playlist-export-test <输出目录> <媒体文件>`（真实走一遍导出 → 清空 → 导入 → 再导出）。

## 星标（收藏）

播放列表每一行右侧有星号，点一下切换；右键菜单也有「加星标 / 取消星标」。
星标**只影响显示，不改变列表顺序**，随 `playlist.json` 跨会话保留。
老版本落盘的列表没有该字段也能正常读出（`isFavorite` 用 `decodeIfPresent` 兜底）。

## 全屏交互

全屏 = **纯视频画面**：侧栏、控制条、窗口工具栏全部收起。
鼠标移动时底部浮现一条材质控制条（含进度条/关键帧标记/音量/截图/置顶），
静止 3 秒自动淡出；顶部短暂显示片名。
退出全屏：↩ / Esc / 双击画面 / 控制条上的全屏按钮。

**实现要点（改动前请先读）**：

1. **视频视图的结构身份必须固定**。`ContentView` 里不能写成
   `if isFullScreen { 全屏布局 } else { 普通布局 }` 然后两边各放一个 `VideoStage()`
   —— 那样切全屏会销毁一个 `MPVGLView`、新建另一个，而一个 mpv 句柄
   **只能有一个** `mpv_render_context`：实测两个视图会来回 attach/detach 互相抢，
   抢输的那个拿不到上下文，表现为「切一次全屏后画面不再渲染」（并且是
   `-20` 与野指针崩溃的来源）。正确做法：`HSplitView` 与其中的 `VideoStage` 恒在，
   全屏只增删它**后面的兄弟节点**（SwiftUI 的身份 = 类型 + 在父节点中的位置）。
2. **全屏状态以窗口为准**。`NSWindow.styleMask.contains(.fullScreen)` 是权威信号；
   `didEnterFullScreenNotification` 实测在非交互启动（从终端跑）时根本不发，
   只靠通知会让全屏布局永不激活 —— 这正是「全屏播放时界面上还留着侧栏和控制条」的根因。
   现在用 `DispatchSourceTimer`（4Hz，不能用 `Timer`：它会因 run loop 模式停摆）
   读窗口状态，并**必须跳过 AppKit 内部窗口**（`_NSFullScreenTransitionOverlayWindow`
   的 `isVisible` 为真且没有全屏位，误取它就永远读到 false）。

## 两个必须知道的技术约束

1. **视频嵌入只能用 render API**。mpv 0.39 起移除了 macOS 的 `wid`（NSView）嵌入
   （旧 cocoa 后端被删，传 `wid` 会被忽略），旧写法会导致播放时弹出一个独立窗口。
   现在由 `MPVGLView`（`NSOpenGLView`）提供 GL 上下文，用 `mpv_render_context_render`
   逐帧驱动绘制，`vo=libmpv`。
2. **退出时必须非阻塞销毁**。mpv 的 macOS 渲染层跑在主线程，若在
   `deinit`/terminate 里 `eventQueue.sync` 等事件线程，会与「事件线程等主线程」
   形成死锁（表现为 ⌘Q 卡死）。现在是置终止标志后把销毁排到事件队列尾部，
   并先释放 render context 再销毁句柄。

## 快捷键自定义

设置 → 快捷键：点方框后按下新组合键即可改绑（Esc 取消），支持冲突提示、
单项恢复默认、清除绑定、全部恢复默认。绑定存 UserDefaults，只记录与默认不同的项；
清除绑定与未设置是两种状态。默认键位表同时作为单元测试的断言基准。

## 代码结构

```
Sources/
  CMPV/                 libmpv C 接口（SPM systemLibrary，走 pkg-config）
  GaleCore/           纯逻辑，仅依赖 Foundation，可单测
    ChapterBook.swift     关键帧模型 + 算法（DMM 原样移植）
    ChapterStore.swift    关键帧持久化（JSON，按 mediaKey 归档）
    Playlist.swift        播放列表树 + 文件夹扫描 + 自然序 + 持久化
    PlaybackQueue.swift   播放顺序与上一集/下一集
    MediaKey.swift        媒体稳定标识（路径+大小+修改时间摘要）
    MediaTypes.swift      支持的 82 个扩展名（取自原版 Info.plist）
    KeyCombo.swift        按键组合模型（特殊键用私有区码位）
    HotKeyAction.swift    可绑定操作 + 默认键位（暴风 + DMM）
    HotKeyStore.swift     绑定持久化 / 覆盖 / 冲突检测
  GalePlayer/         GUI 层
    MPVClient.swift       libmpv 封装（只调公开 C API，vo=libmpv）
    MPVGLView.swift       render API 渲染视图（NSOpenGLView + 逐帧驱动）
    PlayerCore.swift      播放状态 + 关键帧操作
    VideoStage.swift      视频舞台 + 拖放
    ControlBar.swift      播放条（三档自适应密度）+ 关键帧标记点
    SidebarPanel.swift    播放列表 / 关键帧 面板
    ShortcutRecorder.swift 快捷键录制控件
    GaleApp.swift       @main + 菜单快捷键（从 HotKeyStore 取值）
    SettingsView.swift    通用 / 快捷键 / 播放列表 三页（对应原版设置页）
    Diagnostics.swift     --diagnose 解码自检
    WindowReport.swift    --window-report 窗口与布局自检
```

## 关键帧功能的数据模型

```json
{
  "<mediaKey>": {
    "mediaKey": "…",
    "title": "影片名",
    "times": [12, 45, 103]
  }
}
```

`times` 为秒级整数、始终升序。算法逐条对应 DMM 原实现：

- 添加：`floor(当前时间)`，已存在则忽略，插入后排序
- 删除：删「当前时间之前最近的一个」（最后一个严格小于当前时间的），并跳转到该点
- 下一个：第一个严格大于当前时间的关键帧
- 上一个：逆序找第一个满足 `time + 1 < 当前时间` 的（原实现的 1 秒保护）
- 区间循环：当前所处 `[起点, 终点)` 区间播放跨过终点时回到起点

播放位置之外的上下文（列表、最近播放、设置）存
`~/Library/Application Support/com.kevin.galeplayer/`。

## 许可证路线（重要）

当前链接的是 Homebrew 的 **GPL 版** libmpv → 本 App 若分发必须 GPL 开源。

切到 LGPL（可闭源）需要：
1. 自建 FFmpeg（`--disable-gpl --disable-nonfree`）+ libmpv（meson `-Dgpl=false`）
   —— 解码能力不减（RMVB/HEVC/AV1/VideoToolbox 都在 LGPL 侧），丢的是编码器
   （x264/x265）与 vapoursynth/rubberband 等滤镜，本播放器用不到
2. 把 dylib 集合打进 `Contents/Frameworks/`，用 `install_name_tool` 改写为 `@rpath/...`
3. 加 `com.apple.security.cs.disable-library-validation` 豁免并重新签名

业务代码只依赖 libmpv 公开 C API，换构建**不需要改一行 Swift**。

## 尚未完成 / 已知限制

- 播放列表面板的自动隐藏计时（设置项已存，UI 未接）
- 音轨/字幕轨切换菜单（`MPVClient` 已提供 `audioTracks()` / `subtitleTracks()`，未接 UI）
- 硬解走 `videotoolbox-copy`（copy-back）而非零拷贝，是为换取截图可用；
  若要极致能耗比，需改成用 GL 回读帧来实现截图
- 分发用签名与公证（需要 Apple 开发者账号）
- 图标与最终命名
