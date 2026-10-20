// 生成 Gale Player 应用图标（疾风主题：深靛蓝→青绿渐变 + 播放三角 + 风的流线）
// 用法: swift make_icon.swift <输出目录>
// 产出 .iconset 目录，再交给 iconutil 转 .icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// 画一张 size×size 的图标
func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS 图标留白：整图约 82% 是圆角方块
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237   // 接近 macOS squircle

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // ---- 背景渐变：深靛蓝 → 青绿（风的冷色调）----
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        CGColor(red: 0.09, green: 0.13, blue: 0.28, alpha: 1),
        CGColor(red: 0.12, green: 0.34, blue: 0.46, alpha: 1),
        CGColor(red: 0.16, green: 0.62, blue: 0.60, alpha: 1)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }

    // ---- 风的流线：三条从左下到右上的弧线 ----
    ctx.setLineCap(.round)
    for (i, factor) in [0.30, 0.45, 0.60].enumerated() {
        let y0 = rect.minY + rect.height * factor
        let alpha = 0.30 - CGFloat(i) * 0.06
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        ctx.setLineWidth(rect.width * 0.030)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: y0))
        p.addCurve(to: CGPoint(x: rect.maxX - rect.width * 0.10, y: y0 + rect.height * 0.10),
                   control1: CGPoint(x: rect.minX + rect.width * 0.45, y: y0 + rect.height * 0.055),
                   control2: CGPoint(x: rect.maxX - rect.width * 0.34, y: y0 + rect.height * 0.005))
        ctx.addPath(p)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // ---- 播放三角（白色，带柔和阴影）----
    let cx = rect.minX + rect.width * 0.545
    let cy = rect.minY + rect.height * 0.50
    let h = rect.height * 0.30
    let w = h * 0.88

    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: cx - w * 0.5, y: cy + h * 0.5))
    tri.addLine(to: CGPoint(x: cx - w * 0.5, y: cy - h * 0.5))
    tri.addLine(to: CGPoint(x: cx + w * 0.62, y: cy))
    tri.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.030,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(tri)
    ctx.fillPath()
    ctx.restoreGState()

    // ---- 圆角边框：增强立体感和边界 ----
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// iconset 需要的尺寸（含 @2x）
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, px) in specs {
    guard let img = drawIcon(size: px) else { print("生成失败: \(name)"); continue }
    write(img, to: "\(outDir)/\(name)")
}
// 顺带存一张 1024 预览图
if let preview = drawIcon(size: 1024) {
    write(preview, to: "\(outDir)/../icon-preview-1024.png")
}
print("图标已生成到 \(outDir)")
