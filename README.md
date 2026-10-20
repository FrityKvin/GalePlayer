# Gale Player

macOS 原生视频播放器（Apple Silicon，macOS 14+），基于 libmpv / FFmpeg 9 内核。

万能格式、关键帧标记、播放列表管理、播放进度记忆——常用功能齐全，操作习惯参考经典桌面播放器设计。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![arm64](https://img.shields.io/badge/arch-arm64-green) ![license](https://img.shields.io/badge/license-GPL--2.0--or--later-orange)

## 下载安装

从 [Releases](https://github.com/FrityKvin/GalePlayer/releases/latest) 下载最新 DMG：

1. 打开 DMG，把 **Gale Player** 拖进「Applications」文件夹
2. **首次打开**：右键点击 App →「打开」→ 在弹窗里再点一次「打开」
   （未做 Apple 公证时的标准动作，只需做一次；或在终端执行
   `xattr -dr com.apple.quarantine "/Applications/Gale Player.app"`）
3. 需要 Apple Silicon（M 系列）芯片，macOS 14 或更高版本

## 功能

### 播放

- **万能格式**：RMVB / HEVC(H.265) / AV1 / VP9 / H.264 / MKV / FLV / WMV…（VideoToolbox 硬解，4K 流畅）
- 双击画面进/出全屏；单击画面播放/暂停
- 滚轮控制：纵向滚轮调音量，横向滚轮（或 ⇧+纵向）调进度，中键拖动调音量
- 播放速度 0.5x–2.0x；截图自动存到「图片/Gale」；媒体键（F7/F8/F9）支持

### 关键帧

给单个视频打关键帧，随时一键跳回：

- ⌘A 添加 · ⌘D 删除 · ⌘N 上一个 · ⌘P 下一个
- 进度条上显示关键帧标记点
- 关键帧跟着视频文件走：导出播放列表时一起带走，导入即恢复

### 播放列表

- 拖入文件或**整个文件夹**（自动扫描内部媒体），文件夹折叠显示
- 自动高亮正在播放的文件，所在文件夹自动展开
- 星标收藏（右键菜单或行内星号）
- 导出 / 导入播放列表（层级、星标、关键帧一起带走）
- 全屏时鼠标贴近屏幕右缘出现箭头，点击弹出播放列表浮层，鼠标离开自动收起

### 记忆

- **播放进度**：播放过的文件下次打开自动跳回上次位置（开头 10 秒内不记、看完自动清除、30 天未播过期）
- 窗口位置、音量、播放速度、文件夹展开状态都记住

### 更新

- 启动自动检查新版本（每天最多一次，失败静默；可在设置里关闭），也可应用菜单「检查更新…」手动检查
- 发现新版弹窗提示，一键前往下载

## 默认快捷键

| 动作 | 按键 |
|---|---|
| 播放 / 暂停 | 空格 |
| 快退 / 快进 N 秒 | ← / → |
| 快退 / 快进 60 秒 | ⇧← / ⇧→ |
| 上一个 / 下一个视频 | ⌘↑ / ⌘↓ |
| 添加 / 删除关键帧 | ⌘A / ⌘D |
| 上一个 / 下一个关键帧 | ⌘N / ⌘P |
| 音量 | ↑ / ↓ |
| 静音 | ⌘M |
| 截图 | ⌘S |
| 全屏 | ⌘F |
| 窗口置顶 | ⌘T |
| 打开文件 / 文件夹 | ⌘O / ⇧⌘O |
| 导出 / 导入播放列表 | ⇧⌘E / ⇧⌘I |

所有快捷键都可以在 **设置 → 快捷键** 里改绑（点击方框后按下新组合键录制，Esc 取消）。

## 从源码构建

需要 macOS 14+、Xcode（含命令行工具）、Homebrew 的 mpv：

```bash
brew install mpv
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"

# 本机自用版（链接 Homebrew 的 libmpv）
./Scripts/make_app.sh release

# 分发版（依赖全部内嵌进 .app，产出 dist/*.dmg）
./Scripts/make_dist.sh release

# 单元测试
swift test
```

## 开发自检

App 内置一组命令行自检（回归验证用）：

```bash
BIN="build/Gale Player.app/Contents/MacOS/GalePlayer"
"$BIN" --diagnose <媒体>       # 例：解码链路自检
```

| 自检 | 验证什么 |
|---|---|
| `--diagnose <媒体>` | 解码器、分辨率、硬解、丢帧、窗口数 |
| `--window-report <媒体>` | 窗口数量、全屏进出、多尺寸布局 |
| `--hotkeys` | 当前生效键位表（含改绑标记） |
| `--menu-test` | 菜单与 ⌘Q 路由 |
| `--input-test <媒体>` | 快捷键真实生效（播放状态/进度变化） |
| `--mouse-test <媒体>` | 单击暂停、双击全屏、控制条、右缘箭头 |
| `--lifecycle-test <媒体>` | 视图反复重建无崩溃 |
| `--ui-rebuild-test <媒体>` | 普通布局↔全屏切换 4 轮 |
| `--resume-test <媒体> [秒]` | 播放进度记录→落盘→恢复 |
| `--highlight-test <媒体…>` | 播放列表高亮跟随 |
| `--folder-highlight-test <目录>` | 文件夹内高亮 + 「下一个」跟随 |
| `--playlist-export-test <目录> <媒体>` | 导出→清空→导入闭环 |
| `--scroll-conflict-test <媒体>` | 列表滚轮与音量互不干扰 |
| `--update-check` | GitHub 更新检查链路 |
| `--list-folder <目录>` | 文件夹扫描结果 |

## 代码结构

```
Sources/
  CMPV/               libmpv C 接口（SPM systemLibrary，走 pkg-config）
  GaleCore/           纯逻辑层（仅 Foundation，可单测）
    Playlist / ChapterBook / PlaybackQueue / HotKeyStore / UpdateCheck …
  GalePlayer/         GUI 层（SwiftUI + AppKit）
    MPVClient / MPVGLView / PlayerCore / ContentView / ControlBar / SidebarPanel …
Scripts/
  make_app.sh         本机构建（链接 Homebrew libmpv）
  make_dist.sh        分发打包（依赖内嵌 + DMG）
  bundle_deps.py      依赖闭包内嵌与 @rpath 改写
  make_licenses.py    第三方许可证收集
  verify_dist.py      自包含校验（出包门禁）
```

## 许可证

本项目按 GPL-2.0-or-later 发布。分发包内嵌了 mpv、FFmpeg 等第三方组件，
它们的许可证全文见 App 包内 `Contents/Resources/licenses/`
（`THIRD-PARTY-NOTICES.md` 列出各组件版本、许可证与源码地址）。
