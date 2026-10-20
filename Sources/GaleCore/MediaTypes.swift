import Foundation

/// 支持的媒体类型。
///
/// 基础清单覆盖常见视频/音频格式（82 个扩展名，
/// 即原版能「万能播放」的全部关联格式 —— 证据：`plutil -p` 提取），
/// 去掉已决定不做的 `bhd`、并补齐现代格式（`avif`/`webm` 已在列，追加
/// 字幕 `ass`/`vtt` 与音频 `mka`/`opus`）。
public enum MediaTypes {
    public static let video: Set<String> = [
        "3g2", "3gp", "3gp2", "3gpp", "amv", "asf", "avi", "bik", "csf", "dat",
        "divx", "dv", "evo", "f4v", "flv", "gxf", "hlv", "ivm", "m1v", "m2p",
        "m2t", "m2ts", "m2v", "m4v", "m4p", "mkv", "mod", "mov", "mp4", "mpe",
        "mpeg", "mpeg4", "mpg", "mpv2", "mts", "mxf", "nsv", "ogm", "ogv", "pmp",
        "pva", "qt", "rm", "rmvb", "smk", "swf", "tod", "ts", "vob", "vp6",
        "webm", "wm", "wmv", "xlmv", "y4m", "mvi", "roq", "wtv",
    ]

    public static let audio: Set<String> = [
        "aac", "ac3", "aif", "aiff", "amr", "ape", "au", "dts", "eac3", "flac",
        "m1a", "m2a", "m4a", "m4b", "mka", "mp2", "mp3", "mpa", "oga", "ogg",
        "opus", "ra", "tak", "tta", "wav", "wma", "wv", "caf", "sln",
    ]

    public static let subtitle: Set<String> = [
        "ass", "ssa", "srt", "sub", "vtt", "smi", "idx", "sup", "ttml", "lrc",
    ]

    public static let playlist: Set<String> = ["m3u", "m3u8", "pls", "cue", "smpl"]

    public static var all: Set<String> { video.union(audio) }

    public static func ext(_ url: URL) -> String {
        url.pathExtension.lowercased()
    }

    public static func isSupported(_ url: URL) -> Bool {
        let e = ext(url)
        if e.isEmpty { return false }
        return video.contains(e) || audio.contains(e)
    }

    public static func isSubtitle(_ url: URL) -> Bool { subtitle.contains(ext(url)) }

    public static func isVideo(_ url: URL) -> Bool { video.contains(ext(url)) }
    public static func isAudio(_ url: URL) -> Bool { audio.contains(ext(url)) }

    /// `NSOpenPanel` 用：所有可播放格式。
    public static var openPanelExtensions: [String] {
        all.sorted()
    }

    /// SwiftUI `fileImporter` 用。
    public static var contentTypes: [String] { openPanelExtensions }
}
