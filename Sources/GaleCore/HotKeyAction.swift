import Foundation

/// 可绑定的操作。
///
/// 默认按键来自两处证据：
/// 媒体切换 ⌘↑/⌘↓，关键帧跳转 ⌘N/⌘P。
public enum HotKeyAction: String, CaseIterable, Codable, Sendable {
    // 播放
    case playPause
    case stop
    case seekBackward
    case seekForward
    case seekBackwardLong
    case seekForwardLong
    case previousMedia
    case nextMedia
    case speedUp
    case speedDown
    case speedReset

    // 音量与画面
    case volumeUp
    case volumeDown
    case mute
    case screenshot
    case fullScreen
    case alwaysOnTop

    // 文件
    case openFile
    case openFolder

    // 关键帧
    case chapterAdd
    case chapterDelete
    case chapterPrevious
    case chapterNext

    public enum Category: String, CaseIterable, Sendable {
        case playback = "播放"
        case volume = "音量与画面"
        case file = "文件"
        case chapter = "关键帧"
    }

    public var category: Category {
        switch self {
        case .playPause, .stop, .seekBackward, .seekForward, .seekBackwardLong,
             .seekForwardLong, .previousMedia, .nextMedia, .speedUp, .speedDown, .speedReset:
            .playback
        case .volumeUp, .volumeDown, .mute, .screenshot, .fullScreen, .alwaysOnTop:
            .volume
        case .openFile, .openFolder:
            .file
        case .chapterAdd, .chapterDelete, .chapterPrevious, .chapterNext:
            .chapter
        }
    }

    public var title: String {
        switch self {
        case .playPause: "播放 / 暂停"
        case .stop: "停止"
        case .seekBackward: "快退 10 秒"
        case .seekForward: "快进 10 秒"
        case .seekBackwardLong: "快退 60 秒"
        case .seekForwardLong: "快进 60 秒"
        case .previousMedia: "上一个视频"
        case .nextMedia: "下一个视频"
        case .speedUp: "加速播放"
        case .speedDown: "减速播放"
        case .speedReset: "恢复常速"
        case .volumeUp: "提高音量"
        case .volumeDown: "降低音量"
        case .mute: "静音"
        case .screenshot: "截图"
        case .fullScreen: "全屏 / 退出全屏"
        case .alwaysOnTop: "窗口置顶"
        case .openFile: "打开文件"
        case .openFolder: "打开文件夹"
        case .chapterAdd: "添加关键帧"
        case .chapterDelete: "删除关键帧"
        case .chapterPrevious: "上一个关键帧"
        case .chapterNext: "下一个关键帧"
        }
    }

    public var defaultCombo: KeyCombo {
        switch self {
        case .playPause: KeyCombo(key: KeyCombo.SpecialKey.space)
        case .stop: KeyCombo(key: "s", command: true)
        case .seekBackward: KeyCombo(key: KeyCombo.SpecialKey.left)
        case .seekForward: KeyCombo(key: KeyCombo.SpecialKey.right)
        case .seekBackwardLong: KeyCombo(key: KeyCombo.SpecialKey.left, shift: true)
        case .seekForwardLong: KeyCombo(key: KeyCombo.SpecialKey.right, shift: true)
        case .previousMedia: KeyCombo(key: KeyCombo.SpecialKey.up, command: true)
        case .nextMedia: KeyCombo(key: KeyCombo.SpecialKey.down, command: true)
        case .speedUp: KeyCombo(key: "]", command: true)
        case .speedDown: KeyCombo(key: "[", command: true)
        case .speedReset: KeyCombo(key: "0", command: true)
        case .volumeUp: KeyCombo(key: KeyCombo.SpecialKey.up)
        case .volumeDown: KeyCombo(key: KeyCombo.SpecialKey.down)
        case .mute: KeyCombo(key: "m", command: true)
        // ⇧F5：截图
        case .screenshot: KeyCombo(key: KeyCombo.SpecialKey.function(5), shift: true)
        case .fullScreen: KeyCombo(key: KeyCombo.SpecialKey.ret)
        case .alwaysOnTop: KeyCombo(key: "t", command: true)
        case .openFile: KeyCombo(key: "o", command: true)
        case .openFolder: KeyCombo(key: "f", command: true)
        case .chapterAdd: KeyCombo(key: "a", command: true)
        case .chapterDelete: KeyCombo(key: "d", command: true)
        case .chapterPrevious: KeyCombo(key: "p", command: true)
        case .chapterNext: KeyCombo(key: "n", command: true)
        }
    }
}
