// 图标生成器。纯 Core Graphics，无外部依赖，输出确定性。
//
// 用法：
//   swiftc -O -o /tmp/icongen tools/icon/draw.swift
//   /tmp/icongen <Assets.xcassets 路径> <预览图输出目录>
//
// 产出：
//   AppIcon.appiconset/      浅色 + 深色两套，10 个尺寸各一张
//   MenuBarIcon.imageset/    菜单栏单色 template
//   <预览目录>/*.png          1024 / 32 / 16 的对照样张，不入库
//
// 几何都在 1024 画布、内容区 824×824（Apple 的 macOS 图标网格）。
// 所有坐标用「上到下」书写，落笔时用 F() 翻成 Core Graphics 的下到上。

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let CANVAS: CGFloat = 1024
let SRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - 颜色

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: SRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

struct Palette {
    let top: CGColor
    let bottom: CGColor
    let green: CGColor
    let amber: CGColor
}

/// 取自 Theme.swift：绿 = 有效链接，琥珀 = 未链接提及。
let lightPalette = Palette(
    top: rgb(0xFBFAF6), bottom: rgb(0xEAE5DA),
    green: rgb(0x1A6B47), amber: rgb(0x9E7A14)
)
let darkPalette = Palette(
    top: rgb(0x272B29), bottom: rgb(0x141614),
    green: rgb(0x7AC79E), amber: rgb(0xD9B859)
)

// MARK: - 几何工具

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
}

func normalize(_ v: CGPoint) -> CGPoint {
    let len = max(hypot(v.x, v.y), 0.0001)
    return CGPoint(x: v.x / len, y: v.y / len)
}

/// 二次贝塞尔取点，全程用「上到下」坐标。
func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(
        x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
        y: u * u * a.y + 2 * u * t * c.y + t * t * b.y
    )
}

func quadTangent(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(
        x: 2 * (1 - t) * (c.x - a.x) + 2 * t * (b.x - c.x),
        y: 2 * (1 - t) * (c.y - a.y) + 2 * t * (b.y - c.y)
    )
}

// MARK: - 画布

func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: SRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / CANVAS, y: CGFloat(size) / CANVAS)
    return ctx
}

let contentRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let contentPath = CGPath(roundedRect: contentRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

func drawBackground(_ ctx: CGContext, _ p: Palette) {
    ctx.saveGState()
    ctx.addPath(contentPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: SRGB, colors: [p.top, p.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )
    ctx.restoreGState()
}

// MARK: - 方向 C：一枝 + 一个游离的点

/// 主干弧线的三个控制点（上到下坐标）。
let stemA = CGPoint(x: 452, y: 762)
let stemCtl = CGPoint(x: 404, y: 560)
let stemB = CGPoint(x: 604, y: 336)
/// 内容整体缩到 90%，再平移到 824 区域正中。
let branchScale: CGFloat = 0.92
let branchShift = CGPoint(x: -33, y: 16)

func branchTransform(_ pt: CGPoint) -> CGPoint {
    let center = CGPoint(x: 512, y: 512)
    let s = center + (pt - center) * branchScale + branchShift
    return CGPoint(x: s.x, y: CANVAS - s.y)
}

func drawBranch(_ ctx: CGContext, _ p: Palette, detailed: Bool) {
    func F(_ x: CGFloat, _ y: CGFloat) -> CGPoint { branchTransform(CGPoint(x: x, y: y)) }

    // 主干。小尺寸加粗，否则 16px 只剩 1px 的淡线。
    ctx.setStrokeColor(p.green)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(detailed ? 68 : 144)
    ctx.move(to: F(stemA.x, stemA.y))
    ctx.addQuadCurve(to: F(stemB.x, stemB.y), control: F(stemCtl.x, stemCtl.y))
    ctx.strokePath()

    // 叶：从主干 40% 处向左上抽出，根部埋进主干
    let t: CGFloat = 0.40
    let root = quadPoint(stemA, stemCtl, stemB, t)
    let dir = CGPoint(x: -0.60, y: -0.80)
    let normal = CGPoint(x: -dir.y, y: dir.x)
    let len: CGFloat = detailed ? 300 : 318
    let halfW: CGFloat = detailed ? 70 : 96
    let base = root + dir * 74
    let tip = root + dir * len
    let c1 = base + dir * (len * 0.28) + normal * halfW
    let c2 = tip - dir * (len * 0.28) + normal * halfW
    let c3 = tip - dir * (len * 0.28) - normal * halfW
    let c4 = base + dir * (len * 0.28) - normal * halfW
    let leaf = CGMutablePath()
    leaf.move(to: branchTransform(base))
    leaf.addCurve(to: branchTransform(tip), control1: branchTransform(c1), control2: branchTransform(c2))
    leaf.addCurve(to: branchTransform(base), control1: branchTransform(c3), control2: branchTransform(c4))
    leaf.closeSubpath()
    ctx.setFillColor(p.green)
    ctx.addPath(leaf)
    ctx.fillPath()

    // 点串：沿主干末梢的延长线，越远越小
    let u = normalize(stemB - stemCtl)
    ctx.setFillColor(p.amber)
    func dot(_ center: CGPoint, _ radius: CGFloat) {
        let c = branchTransform(center)
        let r = radius * branchScale
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    let tail: [(CGFloat, CGFloat)] = detailed ? [(104, 25), (172, 16)] : []
    for (d, r) in tail { dot(stemB + u * d, r) }
    // 游离点：与末梢留空隙，表示「尚未连接」
    dot(stemB + u * (detailed ? 252 : 206), detailed ? 50 : 64)
}

// MARK: - 方向 A：年轮断口（对照用）

func drawRings(_ ctx: CGContext, _ p: Palette, detailed: Bool) {
    let center = CGPoint(x: 512, y: 512)
    func stroke(_ radius: CGFloat, _ width: CGFloat, _ color: CGColor) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.strokeEllipse(in: CGRect(
            x: center.x - radius, y: CANVAS - center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
    if detailed {
        stroke(330, 56, p.green)
        stroke(246, 46, p.green)
        ctx.setLineDash(phase: 0, lengths: [30, 38])
        stroke(162, 40, p.amber)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(p.amber)
        let r: CGFloat = 34
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: CANVAS - center.y - r, width: r * 2, height: r * 2))
    } else {
        stroke(330, 62, p.green)
        stroke(160, 42, p.amber)
    }
}

// MARK: - 方向 B：两点一线（对照用）

func drawNodes(_ ctx: CGContext, _ p: Palette, detailed: Bool) {
    let shift = CGPoint(x: -18, y: -13)
    func F(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x + shift.x, y: CANVAS - (pt.y + shift.y)) }
    let n1 = CGPoint(x: 372, y: 700)
    let n2 = CGPoint(x: 690, y: 352)
    let r: CGFloat = 62
    let u = normalize(n2 - n1)
    let mid = n1 + (n2 - n1) * 0.5

    // 已连上的那半段
    ctx.setStrokeColor(p.green)
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.move(to: F(n1))
    ctx.addLine(to: F(mid))
    ctx.strokePath()

    // 未连上的那半段
    ctx.setStrokeColor(p.amber)
    if detailed { ctx.setLineDash(phase: 0, lengths: [34, 30]) }
    ctx.move(to: F(mid + u * 26))
    ctx.addLine(to: F(n2))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    ctx.setFillColor(p.green)
    for n in [n1, n2] {
        let c = F(n)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

// MARK: - 渲染

enum Concept: String, CaseIterable {
    case rings, nodes, branch
}

func drawIcon(_ concept: Concept, _ p: Palette, size: Int) -> CGImage {
    let ctx = makeContext(size)
    let detailed = size >= 64
    drawBackground(ctx, p)
    ctx.saveGState()
    ctx.addPath(contentPath)
    ctx.clip()
    switch concept {
    case .rings: drawRings(ctx, p, detailed: detailed)
    case .nodes: drawNodes(ctx, p, detailed: detailed)
    case .branch: drawBranch(ctx, p, detailed: detailed)
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// 菜单栏单色 template：只要 alpha，画得更粗以扛住 16pt。
func drawMenuBar(size: Int) -> CGImage {
    let ctx = makeContext(size)
    let black = rgb(0x000000)
    ctx.setFillColor(black)
    ctx.setStrokeColor(black)
    ctx.setLineCap(.round)
    let shift = CGPoint(x: -30, y: 0)
    func F(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + shift.x, y: CANVAS - (y + shift.y)) }
    ctx.setLineWidth(132)
    ctx.move(to: F(370, 800))
    ctx.addQuadCurve(to: F(620, 430), control: F(470, 620))
    ctx.strokePath()

    ctx.setLineWidth(120)
    ctx.move(to: F(520, 620))
    ctx.addLine(to: F(340, 500))
    ctx.strokePath()

    let freeR: CGFloat = 105
    let c = F(806, 250)
    ctx.fillEllipse(in: CGRect(x: c.x - freeR, y: c.y - freeR, width: freeR * 2, height: freeR * 2))
    return ctx.makeImage()!
}

// MARK: - 落盘

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("无法写 PNG: \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 落盘失败: \(path)") }
}

func upscale(_ image: CGImage, factor: Int) -> CGImage {
    let w = image.width * factor, h = image.height * factor
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: SRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

func write(_ text: String, _ path: String) {
    try! text.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - 主流程

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("用法: icongen <Assets.xcassets> <预览目录>\n".data(using: .utf8)!)
    exit(2)
}
let catalogDir = args[1]
let previewDir = args[2]
let fm = FileManager.default
try! fm.createDirectory(atPath: previewDir, withIntermediateDirectories: true)

// 1. AppIcon.appiconset
let iconDir = catalogDir + "/AppIcon.appiconset"
let darkDir = previewDir + "/dark"
try? fm.removeItem(atPath: iconDir)
try! fm.createDirectory(atPath: iconDir, withIntermediateDirectories: true)
try? fm.removeItem(atPath: darkDir)
try! fm.createDirectory(atPath: darkDir, withIntermediateDirectories: true)

let slots: [(size: String, scale: String, px: Int)] = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]

var imageEntries: [String] = []
for slot in slots {
    let base = "icon_\(slot.size)\(slot.scale == "2x" ? "@2x" : "")"
    let lightName = "\(base).png"
    writePNG(drawIcon(.branch, lightPalette, size: slot.px), "\(iconDir)/\(lightName)")
    writePNG(drawIcon(.branch, darkPalette, size: slot.px), "\(darkDir)/\(base).png")
    imageEntries.append("""
        {
          "filename" : "\(lightName)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)",
          "size" : "\(slot.size)"
        }
    """)
    // 深色变体不进 asset catalog：macOS 深色图标只在 deployment target ≥ 26 时
    // 才会被 actool 收进 Assets.car，本项目是 14.0，写了只会变成 10 条告警。
    // 深色母版按尺寸落到预览目录，等切 Icon Composer 时再取用。
}
write("""
{
  "images" : [
\(imageEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""", iconDir + "/Contents.json")

// 2. MenuBarIcon.imageset
let menuDir = catalogDir + "/MenuBarIcon.imageset"
try? fm.removeItem(atPath: menuDir)
try! fm.createDirectory(atPath: menuDir, withIntermediateDirectories: true)
writePNG(drawMenuBar(size: 16), menuDir + "/menubar_16.png")
writePNG(drawMenuBar(size: 32), menuDir + "/menubar_32.png")
write("""
{
  "images" : [
    { "filename" : "menubar_16.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar_32.png", "idiom" : "mac", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}

""", menuDir + "/Contents.json")

// 3. 预览样张
for concept in Concept.allCases {
    writePNG(drawIcon(concept, lightPalette, size: 1024), "\(previewDir)/\(concept.rawValue)-1024.png")
    writePNG(drawIcon(concept, darkPalette, size: 1024), "\(previewDir)/\(concept.rawValue)-1024-dark.png")
    writePNG(upscale(drawIcon(concept, lightPalette, size: 32), factor: 8), "\(previewDir)/\(concept.rawValue)-32x8.png")
    writePNG(upscale(drawIcon(concept, lightPalette, size: 16), factor: 16), "\(previewDir)/\(concept.rawValue)-16x16.png")
}
writePNG(upscale(drawMenuBar(size: 16), factor: 16), "\(previewDir)/menubar-16x16.png")
writePNG(drawIcon(.branch, lightPalette, size: 128), "\(previewDir)/branch-128.png")
writePNG(drawIcon(.branch, darkPalette, size: 128), "\(previewDir)/branch-128-dark.png")

print("完成：\(catalogDir) / \(previewDir)")
