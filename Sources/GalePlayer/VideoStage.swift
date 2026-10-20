import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI 侧的视频舞台：libmpv 渲染视图 + 拖放打开。
struct VideoStage: View {
    @EnvironmentObject private var core: PlayerCore

    var body: some View {
        MPVVideoView(core: core)
            .background(Color.black)
            .overlay(alignment: .center) {
                if core.currentURL == nil {
                    placeholder
                }
            }
        // ⚠️ 这里**绝对不要**加 `.allowsHitTesting(false)`：
        // 它会连 MPVGLView 一起禁掉，视频区将收不到任何鼠标事件 ——
        // 症状是单击/双击/滚轮、以及依赖点击的播放暂停与全屏**全部失效**。
        // （占位提示自己已有 allowsHitTesting(false)，见 placeholder。）
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.secondary)
            Text("把视频拖进来，或按 ⌘O 打开文件")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("RMVB / HEVC / AV1 等全部格式")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .allowsHitTesting(false)
    }

}

/// 把 `MPVGLView` 桥接给 SwiftUI。
///
/// 不用 `wid` 嵌入：mpv 0.39 起 macOS 的 NSView 嵌入已被移除，只能走 render API
/// （由 `MPVGLView` 提供 GL 上下文并逐帧驱动）。
struct MPVVideoView: NSViewRepresentable {
    let core: PlayerCore

    func makeNSView(context: Context) -> MPVGLView {
        let view = MPVGLView.make()
        view.onClick = { [weak core] in core?.togglePlay() }
        view.onDoubleClick = { [weak core] in core?.toggleFullScreen() }
        // 滚轮：纵向调音量，横向（或 ⇧+纵向）调进度；步长用设置里的秒数
        view.onVolumeWheel = { [weak core] delta in
            guard let core else { return }
            core.adjustVolume(byWheel: delta)
        }
        view.onSeekWheel = { [weak core] delta in
            guard let core else { return }
            core.seek(byWheel: delta)
        }
        view.onMiddleDrag = { [weak core] delta in
            core?.adjustVolume(byMiddleDrag: delta)
        }
        core.attach(glView: view)
        return view
    }

    func updateNSView(_ nsView: MPVGLView, context: Context) {
        // 视图重建时重新绑定（内部幂等）
        core.attach(glView: nsView)
    }

    /// SwiftUI 拆除视图时**必须**显式释放渲染上下文。
    ///
    /// 缺这个钩子就是 incident 5693B60E 的根因：SwiftUI 只释放 NSView 而不通知我们，
    /// mpv 的 render 更新回调仍指向该视图 → 野指针 retain 崩溃；
    /// 同时旧的 mpv_render_context 一直占着 mpv 句柄，新视图再创建会失败（-20）。
    static func dismantleNSView(_ nsView: MPVGLView, coordinator: ()) {
        nsView.detach()
    }
}
