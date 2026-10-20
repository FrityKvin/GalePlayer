import SwiftUI

/// 播放列表悬浮标签（暴风影音同款交互）。
///
/// ⚠️ 关键实现约束：**不能**用 `.overlay` 把这个标签叠在视频视图上。
/// `MPVGLView` 是 `NSOpenGLView`，它在 AppKit 的命中测试里赢过 SwiftUI 浮层
/// （实测右缘内 6pt 处 `hitTest` 返回 MPVGLView），鼠标移动事件被它吃掉，
/// `onHover` 永远不会触发 —— 症状就是「播放时箭头不出现」。
/// 因此它必须是视频视图的**真实兄弟节点**（占 20pt 宽的一列），
/// 几何上不与 GL 视图重叠，命中测试才 unambiguous。
///
/// 行为：鼠标滑入这 20pt 竖带即滑出小箭头；
/// `chevron.left` = 往里推（展开），`chevron.right` = 往外拉（收起）。
struct PlaylistEdgeTab: View {
    /// 右缘箭头本体（普通窗口放在竖列中央，全屏用 overlay 贴到右缘）。
    private var arrow: some View {
        Button(action: onToggle) {
            Image(systemName: isPlaylistOpen ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 44)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(isShown ? 1 : 0)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .help(isPlaylistOpen ? "收起播放列表" : "展开播放列表")
    }

    /// 当前是否处于「播放列表已展开」状态（普通窗口看侧栏，全屏看浮层）。
    let isPlaylistOpen: Bool
    let onToggle: () -> Void
    /// 由外部（窗口级鼠标跟踪）驱动的显隐，用于全屏下的「贴近右缘才出现」。
    /// 为 nil 时退化为只看 `hovering`。
    var isRevealed: Bool?
    /// 保留参数以便将来切换布局；当前**不再使用零宽 overlay**。
    ///
    /// 原因：零宽容器的 overlay 虽然能画出来，但命中测试会失效 ——
    /// 箭头画得出来却点不动。20pt 在 2560pt 宽的屏幕上是 0.8%，肉眼几乎无感，
    /// 用真实列换取「一定点得到」更值。
    var isOverlayMode: Bool = false

    @State private var hovering = false

    private var isShown: Bool {
        if hovering || isPlaylistOpen { return true }
        return isRevealed ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            arrow

            Spacer(minLength: 0)
        }
        .frame(width: 20)
        .frame(maxHeight: .infinity)
        // 整列都是命中区：不用精确点中箭头，鼠标靠近右缘就唤出
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.16), value: isShown)
    }
}