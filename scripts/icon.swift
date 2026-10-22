// 画应用图标，生成 Resources/AppIcon.icns：swift scripts/icon.swift
// 图案是一叠记录：靛蓝底上叠着三张卡片，最前面一张写着字，后面两张是更早的记录。
//
// 本机没有 Xcode，做不了 macOS 26 的 .icon 格式，用 iconutil 出 .icns。身体按 macOS 图标模板画：
// 1024 的画布里 824×824 的圆角矩形，四边留 100。macOS 26 会按自己的圆角裁一次、加玻璃边，不会套灰底。
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// 坐标按左上角原点写，翻成 CG 的。
func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: size - y - height, width: width, height: height)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ g: CGContext, _ path: CGPath, _ fill: CGColor, shadow: (color: CGColor, blur: CGFloat, y: CGFloat)? = nil) {
    g.saveGState()
    if let shadow { g.setShadow(offset: CGSize(width: 0, height: -shadow.y), blur: shadow.blur, color: shadow.color) }
    g.addPath(path)
    g.setFillColor(fill)
    g.fillPath()
    g.restoreGState()
}

func line(_ g: CGContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat, width: CGFloat, _ stroke: CGColor) {
    g.saveGState()
    g.setLineCap(.round)
    g.setLineWidth(width)
    g.setStrokeColor(stroke)
    g.move(to: CGPoint(x: x0, y: size - y))
    g.addLine(to: CGPoint(x: x1, y: size - y))
    g.strokePath()
    g.restoreGState()
}

func draw(_ g: CGContext) {
    let body = rounded(rect(100, 100, 824, 824), 185)
    g.saveGState()
    g.addPath(body)
    g.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x7380F4), color(0x3F45C4)] as CFArray,
                                locations: [0, 1])!
    g.drawLinearGradient(background, start: CGPoint(x: 0, y: size - 100), end: CGPoint(x: 0, y: size - 924), options: [])
    g.restoreGState()

    fill(g, rounded(rect(342, 214, 340, 200), 44), color(0xFFFFFF, 0.38))
    fill(g, rounded(rect(302, 262, 420, 200), 52), color(0xFFFFFF, 0.62))
    fill(g, rounded(rect(262, 318, 500, 500), 60), color(0xFFFFFF), shadow: (color(0x1C1F70, 0.35), 40, 16))
    for (y, end) in [(448.0, 682.0), (548, 682), (648, 582)] {
        line(g, from: 342, to: end, y: y, width: 40, color(0xCDD0F6))
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    g.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    draw(g)
    return rep.representation(using: .png, properties: [:])!
}

let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let output = repo.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print(output.path)
