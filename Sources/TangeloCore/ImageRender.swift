import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Rendering used by the editor windows (Add BG, Annotate, Redact, Edit).
/// All geometry is in image pixels with a top-left origin.
public struct RGBA: Sendable, Hashable, Codable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

// MARK: - Add background

public enum BackgroundFill: Sendable, Hashable {
    case gradient([RGBA], angle: Double)
    case solid(RGBA)

    public static let gradients: [BackgroundFill] = [
        .gradient([RGBA(hex: 0xFF8A3D), RGBA(hex: 0xFF3D77)], angle: 135),
        .gradient([RGBA(hex: 0xF5F7FA), RGBA(hex: 0xC3CFE2)], angle: 135),
        .gradient([RGBA(hex: 0xF9D423), RGBA(hex: 0xFF4E50), RGBA(hex: 0x8E54E9)], angle: 120),
        .gradient([RGBA(hex: 0xFFECD2), RGBA(hex: 0xFCB69F)], angle: 135),
        .gradient([RGBA(hex: 0xE0C3FC), RGBA(hex: 0x8EC5FC)], angle: 135),
        .gradient([RGBA(hex: 0x232526), RGBA(hex: 0x414345)], angle: 135),
        .gradient([RGBA(hex: 0x89F7FE), RGBA(hex: 0x66A6FF)], angle: 135),
        .gradient([RGBA(hex: 0x43E97B), RGBA(hex: 0x38F9D7)], angle: 135),
        .gradient([RGBA(hex: 0xC471F5), RGBA(hex: 0xFA71CD)], angle: 135),
    ]
    public static let solids: [BackgroundFill] = [
        0xFFFFFF, 0xF6C343, 0x9BD45F, 0x3FA34D, 0x2A9D8F, 0x5BC0EB, 0x3A6FF7, 0x1F2937, 0x7C3AED,
    ].map { .solid(RGBA(hex: $0)) }
}

public enum CanvasAspect: String, Sendable, CaseIterable {
    case auto = "Auto", square = "1:1", wide = "16:9", classic = "4:3", tall = "9:16", portrait = "4:5"
    var ratio: Double? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .wide: return 16.0 / 9
        case .classic: return 4.0 / 3
        case .tall: return 9.0 / 16
        case .portrait: return 4.0 / 5
        }
    }
}

public struct BackdropStyle: Sendable, Hashable {
    public var fill: BackgroundFill = BackgroundFill.gradients[0]
    public var padding: Double = 160
    public var cornerRadius: Double = 24
    public var shadow: Double = 24
    public var aspect: CanvasAspect = .auto
    public init() {}
}

public enum ImageRender {
    static func fill(_ ctx: CGContext, _ fill: BackgroundFill, rect: CGRect) {
        switch fill {
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect)
        case .gradient(let colors, let angle):
            let cg = colors.map(\.cgColor) as CFArray
            let locs = colors.indices.map { CGFloat($0) / CGFloat(max(colors.count - 1, 1)) }
            guard let g = CGGradient(colorsSpace: ImageKit.sRGB, colors: cg, locations: locs) else { return }
            let rad = angle * .pi / 180
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let half = (abs(cos(rad)) * rect.width + abs(sin(rad)) * rect.height) / 2
            let d = CGPoint(x: cos(rad) * half, y: -sin(rad) * half)
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// Places the image on a gradient/solid canvas with padding, rounded corners and a soft shadow.
    public static func addBackground(_ image: CGImage, style: BackdropStyle) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        var cw = w + style.padding * 2, ch = h + style.padding * 2
        if let ratio = style.aspect.ratio {
            if cw / ch < ratio { cw = ch * ratio } else { ch = cw / ratio }
        }
        let W = Int(cw.rounded()), H = Int(ch.rounded())
        guard W * H < 300_000_000, let ctx = ImageKit.makeContext(width: W, height: H) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        fill(ctx, style.fill, rect: canvas)
        let frame = CGRect(x: (Double(W) - w) / 2, y: (Double(H) - h) / 2, width: w, height: h)
        let radius = min(style.cornerRadius, min(w, h) / 2)
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if style.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -style.shadow * 0.35), blur: style.shadow * 1.6,
                          color: CGColor(gray: 0, alpha: 0.38))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: frame)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: - Annotations

    public enum AnnotationKind: Sendable, Hashable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case arrow(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case rect(CGRect)
        case ellipse(CGRect)
        case text(String, CGPoint)
        case step(Int, CGPoint)
    }

    public struct Annotation: Sendable, Hashable, Identifiable {
        public let id = UUID()
        public var kind: AnnotationKind
        public var color: RGBA
        public var width: Double
        public init(kind: AnnotationKind, color: RGBA, width: Double) { self.kind = kind; self.color = color; self.width = width }
    }

    /// Draws annotations into a context whose coordinate system is image pixels, top-left origin (y down).
    public static func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for a in annotations {
            ctx.saveGState()
            let color = a.color.cgColor
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(a.width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            switch a.kind {
            case .pen(let pts):
                strokePolyline(pts, ctx)
            case .highlighter(let pts):
                ctx.setStrokeColor(a.color.cgColor.copy(alpha: 0.4)!)
                ctx.setLineWidth(a.width * 3)
                ctx.setLineCap(.square)
                ctx.setBlendMode(.multiply)
                strokePolyline(pts, ctx)
            case .line(let p, let q):
                ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
            case .arrow(let p, let q):
                drawArrow(from: p, to: q, width: a.width, ctx: ctx)
            case .rect(let r):
                ctx.addPath(CGPath(roundedRect: r.standardized, cornerWidth: a.width, cornerHeight: a.width, transform: nil))
                ctx.strokePath()
            case .ellipse(let r):
                ctx.strokeEllipse(in: r.standardized)
            case .text(let s, let p):
                drawText(s, at: p, size: max(a.width * 6, 14), color: color, ctx: ctx)
            case .step(let n, let p):
                let r = max(a.width * 3.2, 14)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                let white = CGColor(gray: 1, alpha: 1)
                drawText("\(n)", at: CGPoint(x: p.x, y: p.y), size: r * 1.15, color: white, ctx: ctx, centered: true)
            }
            ctx.restoreGState()
        }
    }

    static func strokePolyline(_ pts: [CGPoint], _ ctx: CGContext) {
        guard let first = pts.first else { return }
        ctx.move(to: first)
        if pts.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
        // Smooth with quadratic curves through midpoints.
        for i in 1..<max(pts.count, 1) {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            ctx.addQuadCurve(to: mid, control: pts[i - 1])
        }
        if let last = pts.last, pts.count > 1 { ctx.addLine(to: last) }
        ctx.strokePath()
    }

    static func drawArrow(from p: CGPoint, to q: CGPoint, width: Double, ctx: CGContext) {
        let angle = atan2(q.y - p.y, q.x - p.x)
        let head = max(width * 4.5, 16)
        let base = CGPoint(x: q.x - cos(angle) * head * 0.8, y: q.y - sin(angle) * head * 0.8)
        ctx.move(to: p); ctx.addLine(to: base); ctx.strokePath()
        ctx.move(to: q)
        ctx.addLine(to: CGPoint(x: q.x - cos(angle - 0.45) * head, y: q.y - sin(angle - 0.45) * head))
        ctx.addLine(to: CGPoint(x: q.x - cos(angle + 0.45) * head, y: q.y - sin(angle + 0.45) * head))
        ctx.closePath()
        ctx.fillPath()
    }

    static func drawText(_ s: String, at p: CGPoint, size: Double, color: CGColor, ctx: CGContext, centered: Bool = false) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.saveGState()
        // Context is y-down; flip locally so glyphs are upright.
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = centered ? CGPoint(x: -width / 2, y: -(ascent - descent) / 2) : CGPoint(x: 0, y: -ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    public static func renderAnnotations(_ image: CGImage, _ annotations: [Annotation]) -> CGImage? {
        guard let ctx = ImageKit.makeContext(width: image.width, height: image.height, space: image.colorSpace) else { return nil }
        let h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        draw(annotations, in: ctx)
        return ctx.makeImage()
    }

    // MARK: - Redaction

    public enum RedactStyle: String, Sendable, CaseIterable {
        case black = "Black", pixelate = "Pixelate", blur = "Blur"
    }

    public struct Redaction: Sendable, Hashable, Identifiable {
        public let id = UUID()
        public var rect: CGRect
        public var style: RedactStyle
        public init(rect: CGRect, style: RedactStyle) { self.rect = rect; self.style = style }
    }

    public static func renderRedactions(_ image: CGImage, _ items: [Redaction]) -> CGImage? {
        let H = CGFloat(image.height)
        let source = CIImage(cgImage: image)
        var out = source
        for r in items {
            // Convert top-left rect to Core Image's bottom-left space.
            let rect = CGRect(x: r.rect.minX, y: H - r.rect.maxY, width: r.rect.width, height: r.rect.height).integral
                .intersection(source.extent)
            guard !rect.isEmpty else { continue }
            let patch: CIImage
            switch r.style {
            case .black:
                patch = CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.08)).cropped(to: rect)
            case .pixelate:
                // Blocks about half the text height: unreadable, still looks tidy.
                let scale = max(12, min(rect.width, rect.height) / 2.2)
                patch = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY),
                ]).cropped(to: rect)
            case .blur:
                let radius = max(16, min(rect.width, rect.height) / 1.8)
                patch = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: rect)
            }
            out = patch.composited(over: out)
        }
        return CIContext().createCGImage(out, from: source.extent, format: .RGBA8, colorSpace: image.colorSpace ?? ImageKit.sRGB)
    }

    // MARK: - Adjustments

    public struct Adjustments: Sendable, Hashable {
        public var exposure: Double = 0       // -2...2 EV
        public var brightness: Double = 0     // -0.5...0.5
        public var contrast: Double = 1       // 0.5...1.5
        public var saturation: Double = 1     // 0...2
        public var warmth: Double = 0         // -1...1
        public var sharpness: Double = 0      // 0...1
        public var vignette: Double = 0       // 0...1
        public var filter: String? = nil      // CIPhotoEffect* name
        public var quarterTurns: Int = 0
        public var flipH = false
        public var flipV = false
        public init() {}
        public var isIdentity: Bool { self == Adjustments() }
    }

    public static let filters: [(String, String?)] = [
        ("Original", nil), ("Mono", "CIPhotoEffectMono"), ("Noir", "CIPhotoEffectNoir"), ("Tonal", "CIPhotoEffectTonal"),
        ("Chrome", "CIPhotoEffectChrome"), ("Fade", "CIPhotoEffectFade"), ("Instant", "CIPhotoEffectInstant"),
        ("Process", "CIPhotoEffectProcess"), ("Transfer", "CIPhotoEffectTransfer"),
    ]

    public static func apply(_ a: Adjustments, to input: CIImage) -> CIImage {
        var img = input
        if a.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation,
            ])
        }
        if a.warmth != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + a.warmth * 2500, y: 0),
            ])
        }
        if let f = a.filter { img = img.applyingFilter(f) }
        if a.sharpness > 0 { img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness * 2]) }
        if a.vignette > 0 {
            img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette * 1.5, kCIInputRadiusKey: 1.5])
        }
        img = img.cropped(to: input.extent)
        var t = CGAffineTransform.identity
        let e = img.extent
        if a.flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.width, ty: 0)) }
        if a.flipV { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: e.height)) }
        if a.flipH || a.flipV { img = img.transformed(by: t) }
        let q = ((a.quarterTurns % 4) + 4) % 4
        if q != 0 {
            img = img.oriented(q == 1 ? .right : (q == 2 ? .down : .left))
        }
        return img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    public static func render(_ image: CGImage, adjustments: Adjustments, context: CIContext = CIContext()) -> CGImage? {
        let out = apply(adjustments, to: CIImage(cgImage: image))
        return context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: image.colorSpace?.model == .rgb ? image.colorSpace! : ImageKit.sRGB)
    }
}

extension ImageActions {
    /// Saves an edited image next to the original, in the original's format when possible.
    public static func saveEdited(_ image: CGImage, like item: InputItem, suffix: String, forcePNG: Bool = false, ctx: JobContext) async throws {
        if forcePNG {
            try await ctx.produce(ctx.destination(for: item.url, ext: "png", suffix: suffix)) { tmp in
                try ImageKit.write(image, to: tmp, format: .png, quality: 1, settings: ctx.settings)
            }
            return
        }
        let loaded = try? ImageKit.load(item.url, maxPixel: 64)
        try await writeSameFormat(image, like: item, suffix: suffix, loaded: loaded, ctx: ctx)
    }
}
