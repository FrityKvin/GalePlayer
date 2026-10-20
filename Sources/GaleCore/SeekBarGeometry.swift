import Foundation

/// 进度条几何计算。
///
/// 抽到这里是为了能单测：关键帧标记画在进度条上时，位置必须严格等于
/// `time / duration * width`，否则用户会看到「标记和实际时间对不上」。
public enum SeekBarGeometry {
    /// 播放进度条已填充部分的宽度。
    public static func progressWidth(position: Double, duration: Double, width: Double) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        let ratio = min(max(position / duration, 0), 1)
        return width * ratio
    }

    /// 关键帧标记的 x 起点（相对进度条左边缘）。
    ///
    /// - Parameters:
    ///   - time: 关键帧时间（秒）
    ///   - duration: 媒体总时长（秒）
    ///   - width: 进度条宽度（pt）
    ///   - markerWidth: 标记自身宽度，居中落在时间点上
    /// - Returns: 夹在 `0...(width - markerWidth)` 内的 x；时长未知时返回 0
    public static func markerX(
        time: Double,
        duration: Double,
        width: Double,
        markerWidth: Double = 2
    ) -> Double {
        guard duration > 0, width > markerWidth else { return 0 }
        let center = width * min(max(time / duration, 0), 1)
        return min(max(center - markerWidth / 2, 0), width - markerWidth)
    }

    /// 时间 → 进度条上的格式化文本（关键帧列表用）。
    public static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}