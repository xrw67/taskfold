// 生成 Taskfold 应用图标（macOS 11+ 规范：1024 画布，squircle 占 824pt，透明四角）
// 用法：swift scripts/gen_icon.swift <输出目录>

import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

// MARK: - 设计参数

let canvas = 1024.0
let iconSize = 824.0                     // macOS 图标网格：squircle 边长
let origin = (canvas - iconSize) / 2     // (100, 100)
let cornerRadius = iconSize * 0.2245     // macOS 圆角比例

let gradientTop = NSColor(calibratedRed: 0.42, green: 0.55, blue: 1.00, alpha: 1)  // #6B8CFF
let gradientBottom = NSColor(calibratedRed: 0.16, green: 0.25, blue: 0.87, alpha: 1) // #2940DE

func squirclePath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// MARK: - 绘制

func drawIcon(size: CGFloat) -> NSImage {
    let scale = size / canvas
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("无绘图上下文") }
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    let iconRect = NSRect(x: origin, y: origin, width: iconSize, height: iconSize)

    // 1. 投影（先单独画模糊阴影）
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -22)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.set()
    NSColor.black.setFill()
    squirclePath(in: iconRect, radius: cornerRadius).fill()
    ctx.restoreGState()

    // 2. 主体渐变（左上 → 右下微斜）
    ctx.saveGState()
    squirclePath(in: iconRect, radius: cornerRadius).addClip()
    let gradient = NSGradient(
        starting: gradientTop,
        ending: gradientBottom
    )!
    let gStart = NSPoint(x: iconRect.minX + iconRect.width * 0.2, y: iconRect.maxY)
    let gEnd = NSPoint(x: iconRect.maxX - iconRect.width * 0.1, y: iconRect.minY)
    gradient.draw(from: gStart, to: gEnd, options: [])

    // 3. （内高光已移除：贴近边缘的弧线在小尺寸下会渲染成生硬的缺口）
    ctx.restoreGState()

    // 4. 焦点环（focus 寓意的同心细环）
    let ringCenter = NSPoint(x: canvas / 2, y: canvas / 2 - 12)
    let ring = NSBezierPath()
    ring.appendArc(
        withCenter: ringCenter,
        radius: 258,
        startAngle: 0, endAngle: 360
    )
    NSColor.white.withAlphaComponent(0.16).setStroke()
    ring.lineWidth = 14
    ring.stroke()

    // 5. 对勾（圆头圆角，白色）
    let check = NSBezierPath()
    check.move(to: NSPoint(x: ringCenter.x - 138, y: ringCenter.y - 22))
    check.line(to: NSPoint(x: ringCenter.x - 28, y: ringCenter.y - 132))
    check.line(to: NSPoint(x: ringCenter.x + 150, y: ringCenter.y + 116))
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.lineWidth = 76
    NSColor.white.setStroke()
    check.stroke()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

// MARK: - 导出

func exportPNG(_ image: NSImage, size: CGFloat, name: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1.0,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    try! data.write(to: url)
    print("  \(name)")
}

// AppIcon.appiconset 需要的全部尺寸
let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

print("生成图标 → \(outputDir)")
let master = drawIcon(size: canvas)
for (size, name) in sizes {
    exportPNG(master, size: size, name: name)
}
// 预览用大图
exportPNG(master, size: 512, name: "preview_512.png")
print("完成")
