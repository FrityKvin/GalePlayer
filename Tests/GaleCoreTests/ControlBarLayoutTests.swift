import XCTest
@testable import GaleCore

/// 控制栏垂直布局：按钮行必须落在「进度条底部 ↔ 窗口底边」的垂直中点，
/// 且与进度条保持足够的安全间距（防拖动进度条时误触播放控件）。
final class ControlBarLayoutTests: XCTestCase {

    /// 核心：间距必须达到防误操作下限（旧布局只有 6pt）。
    func testGapMeetsSafetyMinimum() {
        XCTAssertGreaterThanOrEqual(
            ControlBarLayout.gap, ControlBarLayout.minimumSafeGap,
            "进度条与按钮行间距 \(ControlBarLayout.gap)pt 低于安全下限 \(ControlBarLayout.minimumSafeGap)pt，拖动进度条会误触按钮"
        )
    }

    /// 旧布局回归钉：修复前间距是 6pt，必须有明显改善。
    func testGapIsLargerThanOldLayout() {
        XCTAssertGreaterThan(
            ControlBarLayout.gap, 6,
            "新布局必须比旧的 6pt 间距更宽"
        )
    }

    /// 按钮行上方间距 == 下方间距（即「上下居中」的精确含义）。
    func testButtonRowSitsCenteredBetweenSeekBarAndBottom() {
        XCTAssertTrue(
            ControlBarLayout.isVerticallyCentered(),
            "按钮行未居中：上间距 \(ControlBarLayout.gap)pt / 下间距 \(ControlBarLayout.bottomInset)pt"
        )
    }

    /// 几何自洽：各段加起来必须等于总高度，且顺序正确（不重叠）。
    func testGeometryIsConsistent() {
        // 无重叠
        XCTAssertGreaterThan(ControlBarLayout.buttonRowTop, ControlBarLayout.seekBarBottom,
                             "按钮行不得压到进度条")
        XCTAssertLessThan(ControlBarLayout.buttonRowBottom, ControlBarLayout.totalHeight,
                          "按钮行不得溢出控制栏底边")

        // 各段和等于总高
        let sum = ControlBarLayout.topPadding
            + ControlBarLayout.seekBarHeight
            + ControlBarLayout.gap
            + ControlBarLayout.buttonRowHeight
            + ControlBarLayout.bottomInset
        XCTAssertEqual(sum, ControlBarLayout.totalHeight, accuracy: 0.01,
                       "各段高度之和应等于控制栏总高（实际 \(sum) vs \(ControlBarLayout.totalHeight)）")
    }

    /// 三条密度档（窗口宽度不同）共用同一套垂直几何 —— 高度不应随宽度变。
    func testLayoutIsWidthIndependent() {
        // 垂直几何是常量，不接收宽度参数；这里断言总高恒定，防止未来有人
        // 按宽度改高度导致按钮行在不同窗口大小下漂移。
        XCTAssertEqual(ControlBarLayout.totalHeight, 76,
                       "控制栏总高应保持 76pt（改变它需要同步更新 gap 断言）")
    }
}
