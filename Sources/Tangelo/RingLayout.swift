import AppKit
import TangeloCore

/// Ring dimensions (points).
enum Ring {
    static let radius: CGFloat = 152      // glass disc
    static let outer: CGFloat = 143       // wedge outer edge
    static let inner: CGFloat = 64        // wedge inner edge
    static let core: CGFloat = 56         // center circle
    static let gap: CGFloat = 6
    static let corner: CGFloat = 13
    static let margin: CGFloat = 30       // room for the shadow and the hover "pop"
    static let tabHeight: CGFloat = 30
    static let tabArea: CGFloat = 34      // space reserved under the disc for page tabs
    /// How far from the center a pointer still counts as over a wedge (a little past the glass rim).
    static let reach: CGFloat = radius + 10

    static var size: NSSize {
        let w = (radius + margin) * 2
        return NSSize(width: w, height: w + tabArea)
    }

    /// Disc center in the ring view's coordinates (y up).
    static var center: NSPoint { NSPoint(x: size.width / 2, y: tabArea + size.width / 2) }
}

/// One wedge's precomputed geometry and label.
struct WedgeLayout {
    let path: CGPath          // centered on the disc origin
    let midAngle: CGFloat
    let labelCenter: CGPoint
    let lines: [String]
    let fontSize: CGFloat
    let icon: NSImage?
    let isGroup: Bool
}

struct RingLayout {
    let entries: [MenuEntry]
    let wedges: [WedgeLayout]

    static let empty = RingLayout(entries: [], wedges: [])

    static func make(_ entries: [MenuEntry]) -> RingLayout {
        let n = entries.count
        guard n > 0 else { return .empty }
        let span = 2 * CGFloat.pi / CGFloat(n)
        var wedges: [WedgeLayout] = []
        for (i, e) in entries.enumerated() {
            let mid = CGFloat.pi / 2 - CGFloat(i) * span
            let path = wedgePath(mid: mid, span: span, inner: Ring.inner, outer: Ring.outer, gap: Ring.gap, corner: Ring.corner)
            let hasIcon = e.symbol != nil
            let rMid = (Ring.inner + Ring.outer) / 2 + (n <= 4 ? 4 : 0)
            let chord = 2 * rMid * sin(min(span, .pi * 0.9) / 2) - Ring.gap - 14
            let radial = Ring.outer - Ring.inner - 18
            let (lines, size) = fit(e.title, maxWidth: max(chord, 40), maxHeight: radial - (hasIcon ? 18 : 0),
                                    preferred: hasIcon ? 9.5 : (n > 8 ? 12 : 13.5))
            var icon: NSImage? = nil
            if let s = e.symbol {
                let cfg = NSImage.SymbolConfiguration(pointSize: n > 8 ? 14 : 16, weight: .semibold)
                icon = NSImage(systemSymbolName: s, accessibilityDescription: e.title)?.withSymbolConfiguration(cfg)
            }
            var isGroup = false
            if case .group = e { isGroup = true }
            wedges.append(WedgeLayout(path: path, midAngle: mid, labelCenter: CGPoint(x: cos(mid) * rMid, y: sin(mid) * rMid),
                                      lines: lines, fontSize: size, icon: icon, isGroup: isGroup))
        }
        return RingLayout(entries: entries, wedges: wedges)
    }

    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .bold) }

    /// Picks one or two lines and a font size that fit the wedge.
    static func fit(_ title: String, maxWidth: CGFloat, maxHeight: CGFloat, preferred: CGFloat) -> ([String], CGFloat) {
        func width(_ s: String, _ size: CGFloat) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font(size), .kern: size * 0.04]).width
        }
        var size = preferred
        while size >= 7.5 {
            if width(title, size) <= maxWidth { return ([title], size) }
            if title.contains(" ") {
                let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.allSatisfy({ width($0, size) <= maxWidth }) && size * 2.3 <= maxHeight + 10 { return (parts, size) }
            }
            size -= 0.5
        }
        return ([title], 7.5)
    }

    /// Annular sector with parallel gaps and rounded corners (shrink, then round by stroking).
    static func wedgePath(mid: CGFloat, span: CGFloat, inner r1: CGFloat, outer r2: CGFloat, gap: CGFloat, corner c: CGFloat) -> CGPath {
        let a0 = mid - span / 2, a1 = mid + span / 2
        let ri = r1 + c, ro = r2 - c
        let off = gap / 2 + c
        let p = CGMutablePath()
        if span >= 2 * .pi - 0.001 {
            p.addEllipse(in: CGRect(x: -ro, y: -ro, width: ro * 2, height: ro * 2))
            p.addEllipse(in: CGRect(x: -ri, y: -ri, width: ri * 2, height: ri * 2))
            return p.copy(strokingWithWidth: 2 * c, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .union(p, using: .evenOdd)
        }
        let ai0 = a0 + asin(min(off / ri, 0.99)), ai1 = a1 - asin(min(off / ri, 0.99))
        let ao0 = a0 + asin(min(off / ro, 0.99)), ao1 = a1 - asin(min(off / ro, 0.99))
        p.addArc(center: .zero, radius: ro, startAngle: ao0, endAngle: max(ao1, ao0 + 0.001), clockwise: false)
        if ai1 > ai0 {
            p.addArc(center: .zero, radius: ri, startAngle: ai1, endAngle: ai0, clockwise: true)
        } else {
            p.addLine(to: CGPoint(x: cos(mid) * ri, y: sin(mid) * ri))
        }
        p.closeSubpath()
        let stroked = p.copy(strokingWithWidth: 2 * c, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return stroked.union(p)
    }

    /// Which wedge is under a point relative to the disc center (nil inside the core / outside the disc).
    func hitTest(_ v: CGPoint) -> Int? {
        let n = entries.count
        guard n > 0 else { return nil }
        let r = hypot(v.x, v.y)
        guard r >= Ring.inner - 6, r <= Ring.reach else { return nil }
        let span = 2 * CGFloat.pi / CGFloat(n)
        var t = (CGFloat.pi / 2 - atan2(v.y, v.x) + span / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if t < 0 { t += 2 * .pi }
        return min(Int(t / span), n - 1)
    }
}

// MARK: - Drawing helpers

enum RingDraw {
    static func label(_ lines: [String], size: CGFloat, color: NSColor, at center: CGPoint, iconBelow: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [.font: RingLayout.font(size), .foregroundColor: color, .kern: size * 0.04]
        let lineHeight = size * 1.18
        let total = lineHeight * CGFloat(lines.count)
        var y = center.y + total / 2 - lineHeight - iconBelow / 2
        for line in lines {
            let s = line as NSString
            let w = s.size(withAttributes: attrs).width
            s.draw(at: CGPoint(x: center.x - w / 2, y: y + (lineHeight - size) / 2 - size * 0.12), withAttributes: attrs)
            y -= lineHeight
        }
    }

    static func icon(_ image: NSImage, color: NSColor, center: CGPoint) {
        let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? image
        let s = tinted.size
        tinted.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }

    static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return t < 0.5 ? a : b }
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                       alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * t)
    }
}
