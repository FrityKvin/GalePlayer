import Foundation

/// 控制栏的垂直布局几何（纯数值，可单测）。
///
/// ## 本次调整（2026-11-20，Kevin 报的真实问题）
/// 旧布局：`VStack(spacing: 6) { 进度条(14pt); 按钮行(20pt) }` —— 进度条与按钮之间
/// **只有 6pt**。进度条的拖动热区高 14pt，手指/鼠标稍微偏下就落到按钮行上，
/// 拖进度时容易误触播放控件。
///
/// 新布局：按钮行放在「进度条底部」与「窗口底边」之间的**垂直中点**，
/// 间距从 6pt 提到 ~17pt（≥ 12pt 的防误操作下限）。
///
/// 注意：这些数值是控制栏的真实布局来源（`ControlBar` 直接用它们算，
/// 测试断言它们，二者不会漂移）。
public enum ControlBarLayout {
    /// 控制栏整体高度（`.frame(height:)`）。
    public static let totalHeight: CGFloat = 76
    /// 顶部内边距（进度条上方留白）。
    public static let topPadding: CGFloat = 8
    /// 进度条视图高度（含 5pt 轨道，标记线是 14pt）。
    public static let seekBarHeight: CGFloat = 14
    /// 按钮行高度（图标 20pt）。
    public static let buttonRowHeight: CGFloat = 20
    /// 左右内边距。
    public static let horizontalPadding: CGFloat = 12

    /// 进度条底部在整体坐标系中的 y。
    public static var seekBarBottom: CGFloat { topPadding + seekBarHeight }

    /// 进度条底部 → 按钮行顶部的间距（防误操作的核心指标）。
    ///
    /// 由「进度条底」到「整体底边」这段剩余空间平分给上下两个弹性间距得出。
    public static var gap: CGFloat {
        let free = totalHeight - seekBarBottom - buttonRowHeight
        return max(0, free / 2)
    }

    /// 按钮行顶部在整体坐标系中的 y（= 进度条底部 + gap）。
    public static var buttonRowTop: CGFloat { seekBarBottom + gap }

    /// 按钮行底部。
    public static var buttonRowBottom: CGFloat { buttonRowTop + buttonRowHeight }

    /// 按钮行到整体底边的距离。
    public static var bottomInset: CGFloat { totalHeight - buttonRowBottom }

    /// 是否「上下居中」：按钮行上方间距与下方间距相等（容差用于浮点误差）。
    public static func isVerticallyCentered(tolerance: CGFloat = 0.5) -> Bool {
        abs(gap - bottomInset) <= tolerance
    }

    /// 防误操作下限：进度条与按钮行之间至少要留这么多，否则拖动进度条会误触按钮。
    public static let minimumSafeGap: CGFloat = 12
}
