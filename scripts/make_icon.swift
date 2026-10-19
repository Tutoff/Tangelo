// Renders Tangelo's app icon (a citrus slice that doubles as the radial menu) into an .icns file.
// Usage: swift scripts/make_icon.swift Resources/AppIcon.icns
import AppKit
import CoreGraphics
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

func wedge(mid: CGFloat, span: CGFloat, r1: CGFloat, r2: CGFloat, gap: CGFloat, corner c: CGFloat) -> CGPath {
    let a0 = mid - span / 2, a1 = mid + span / 2
    let ri = r1 + c, ro = r2 - c, off = gap / 2 + c
    let p = CGMutablePath()
    p.addArc(center: .zero, radius: ro, startAngle: a0 + asin(off / ro), endAngle: a1 - asin(off / ro), clockwise: false)
    p.addArc(center: .zero, radius: ri, startAngle: a1 - asin(min(off / ri, 0.99)), endAngle: a0 + asin(min(off / ri, 0.99)), clockwise: true)
    p.closeSubpath()
    return p.copy(strokingWithWidth: 2 * c, lineCap: .round, lineJoin: .round, miterLimit: 10).union(p)
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    // Squircle background with a warm cream gradient.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0xFFF1E4))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [color(0xFFFBF6), color(0xFFE2C9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 500)
    ctx.translateBy(x: c.x, y: c.y)

    // Leaf
    ctx.saveGState()
    ctx.translateBy(x: 150, y: 285)
    ctx.rotate(by: -0.45)
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: 0, y: 0))
    leaf.addQuadCurve(to: CGPoint(x: 150, y: 0), control: CGPoint(x: 75, y: 78))
    leaf.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: 75, y: -78))
    ctx.addPath(leaf)
    let leafGrad = CGGradient(colorsSpace: srgb, colors: [color(0x7BC96F), color(0x3E9A4B)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.clip()
    ctx.drawLinearGradient(leafGrad, start: CGPoint(x: 0, y: 60), end: CGPoint(x: 150, y: -60), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0x2F7D3A, 0.6)); ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: 8, y: 0)); ctx.addLine(to: CGPoint(x: 135, y: 0)); ctx.strokePath()
    ctx.restoreGState()

    // Peel and pith
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x9A3A10, 0.35))
    ctx.setFillColor(color(0xF2661F))
    ctx.fillEllipse(in: CGRect(x: -330, y: -330, width: 660, height: 660))
    ctx.restoreGState()
    let peel = CGGradient(colorsSpace: srgb, colors: [color(0xFF9442), color(0xE6521A)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: -330, y: -330, width: 660, height: 660)); ctx.clip()
    ctx.drawLinearGradient(peel, start: CGPoint(x: -200, y: 330), end: CGPoint(x: 200, y: -330), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFF4E8))
    ctx.fillEllipse(in: CGRect(x: -298, y: -298, width: 596, height: 596))

    // Segments (one popped out like the ring's hover state)
    let n = 8
    let span = 2 * CGFloat.pi / CGFloat(n)
    let juice = CGGradient(colorsSpace: srgb, colors: [color(0xFFC15E), color(0xFF8A2A)] as CFArray, locations: [0, 1])!
    let hot = CGGradient(colorsSpace: srgb, colors: [color(0xFF8A3D), color(0xEE4F17)] as CFArray, locations: [0, 1])!
    for i in 0..<n {
        let mid = CGFloat.pi / 2 - span / 2 - CGFloat(i) * span
        let selected = i == 1
        var t = selected ? CGAffineTransform(translationX: cos(mid) * 20, y: sin(mid) * 20) : .identity
        let path = wedge(mid: mid, span: span, r1: 60, r2: 278, gap: 18, corner: 14).copy(using: &t)!
        if selected {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0xB83A0C, 0.45))
            ctx.addPath(path)
            ctx.setFillColor(color(0xF25F1D))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawRadialGradient(selected ? hot : juice, startCenter: .zero, startRadius: 60, endCenter: .zero, endRadius: 300, options: [])
        ctx.restoreGState()
        // juicy highlight
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(color(0xFFFFFF, selected ? 0.10 : 0.16))
        ctx.fillEllipse(in: CGRect(x: cos(mid) * 150 - 40, y: sin(mid) * 150 - 18, width: 80, height: 36))
        ctx.restoreGState()
    }
    ctx.setFillColor(color(0xFFF4E8))
    ctx.fillEllipse(in: CGRect(x: -96, y: -96, width: 192, height: 192))
    return ctx.makeImage()!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(cgImage: render(px))
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
try? fm.removeItem(at: out)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
let preview = out.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png")
try? fm.removeItem(at: preview)
try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: preview)
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
