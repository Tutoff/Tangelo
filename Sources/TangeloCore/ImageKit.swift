import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpg, png, heic, webp, avif, tiff, gif, bmp, pdf, ico, icns, jp2, psd, tga

    public var ext: String { rawValue }
    public var title: String { rawValue.uppercased() }

    public var uti: String {
        switch self {
        case .jpg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        case .pdf: return "com.adobe.pdf"
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        case .jp2: return "public.jpeg-2000"
        case .psd: return "com.adobe.photoshop-image"
        case .tga: return "com.truevision.tga-image"
        }
    }

    public var supportsAlpha: Bool { !(self == .jpg || self == .bmp) }
    public var isLossy: Bool { [.jpg, .heic, .avif, .webp, .jp2].contains(self) }

    /// Formats that keep EXIF/GPS metadata when written.
    var carriesMetadata: Bool { [.jpg, .heic, .avif, .tiff, .png, .jp2].contains(self) }

    public init?(formatKey: String) {
        switch formatKey {
        case "jpg": self = .jpg
        case "heic", "heics": self = .heic
        default: self.init(rawValue: formatKey)
        }
    }
}

public struct LoadedImage {
    public let image: CGImage
    /// Source metadata (EXIF, GPS, TIFF, DPI...).
    public let properties: [String: Any]
    public let frameCount: Int

    public var width: Int { image.width }
    public var height: Int { image.height }
}

public enum ImageKit {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Loading

    /// Decodes the primary image with EXIF orientation applied.
    public static func load(_ url: URL, maxPixel: Int? = nil) throws -> LoadedImage {
        if url.pathExtension.lowercased() == "svg" { return try loadSVG(url, maxPixel: maxPixel) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            throw TangeloError.unsupported("Couldn't read \(url.lastPathComponent) as an image.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let full = max(w, h)
        let target = min(maxPixel ?? full, full)
        if target > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) {
                return LoadedImage(image: img, properties: props, frameCount: CGImageSourceGetCount(src))
            }
        }
        guard let img = CGImageSourceCreateImageAtIndex(src, index, nil) else {
            throw TangeloError.unsupported("Couldn't decode \(url.lastPathComponent).")
        }
        return LoadedImage(image: img, properties: props, frameCount: CGImageSourceGetCount(src))
    }

    static func loadSVG(_ url: URL, maxPixel: Int?) throws -> LoadedImage {
        guard let ns = NSImage(contentsOf: url), ns.size.width > 0, ns.size.height > 0 else {
            throw TangeloError.unsupported("Couldn't read \(url.lastPathComponent) as SVG.")
        }
        let longest = max(ns.size.width, ns.size.height)
        var target = min(4096, max(1024, longest * 2))
        if let maxPixel { target = min(target, CGFloat(maxPixel)) }
        let scale = target / longest
        let w = max(1, Int((ns.size.width * scale).rounded()))
        let h = max(1, Int((ns.size.height * scale).rounded()))
        guard let ctx = makeContext(width: w, height: h) else { throw TangeloError.failed("Out of memory.") }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { throw TangeloError.failed("Couldn't render SVG.") }
        return LoadedImage(image: img, properties: [:], frameCount: 1)
    }

    /// SVGs are rendered at this size by `load`, so every action measures them the same way.
    static func svgRasterSize(_ points: CGSize) -> CGSize {
        let longest = max(points.width, points.height)
        guard longest > 0 else { return points }
        let scale = min(4096, max(1024, longest * 2)) / longest
        return CGSize(width: max(1, (points.width * scale).rounded()), height: max(1, (points.height * scale).rounded()))
    }

    public static func pixelSize(of url: URL) -> CGSize? {
        if url.pathExtension.lowercased() == "svg" {
            return NSImage(contentsOf: url).map { svgRasterSize($0.size) }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        let o = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    // MARK: Writing

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double,
                             properties: [String: Any]? = nil, settings: EngineSettings) throws {
        switch format {
        case .webp:
            try WebP.write(image, to: url, quality: quality, settings: settings)
        case .pdf:
            try writePDF(pages: [image], dpi: dpi(properties), to: url)
        case .ico:
            try writeICO(image, to: url, sizes: [16, 24, 32, 48, 64, 128, 256])
        case .icns:
            try writeIconFamily(image, to: url, uti: format.uti, sizes: [16, 32, 64, 128, 256, 512, 1024])
        default:
            var img = image
            if !format.supportsAlpha && hasAlpha(image) { img = flatten(image) ?? image }
            if format == .gif || format == .bmp || format == .tga || format == .psd { img = toSRGB(img) ?? img }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.uti as CFString, 1, nil) else {
                throw TangeloError.unsupported("This Mac can't write \(format.title) files.")
            }
            var props: [String: Any] = format.carriesMetadata ? metadata(from: properties, keepLocation: settings.keepLocation) : [:]
            if format.isLossy { props[kCGImageDestinationLossyCompressionQuality as String] = quality }
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw TangeloError.failed("Couldn't encode \(format.title).")
            }
        }
    }

    /// Keeps the useful metadata and resets orientation (pixels are already upright).
    static func metadata(from source: [String: Any]?, keepLocation: Bool) -> [String: Any] {
        guard let source else { return [:] }
        var out: [String: Any] = [:]
        var keys: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                                kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight]
        if keepLocation { keys.append(kCGImagePropertyGPSDictionary) }
        for k in keys { if let v = source[k as String] { out[k as String] = v } }
        if var tiff = source[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        out[kCGImagePropertyOrientation as String] = 1
        return out
    }

    static func dpi(_ props: [String: Any]?) -> Double {
        let d = (props?[kCGImagePropertyDPIWidth as String] as? Double) ?? 72
        return d > 1 ? d : 72
    }

    public static func writePDF(pages: [CGImage], dpi: Double = 72, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw TangeloError.failed("Couldn't create PDF.")
        }
        for img in pages {
            var box = CGRect(x: 0, y: 0, width: Double(img.width) * 72 / dpi, height: Double(img.height) * 72 / dpi)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.interpolationQuality = .high
            ctx.draw(img, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func writeIconFamily(_ image: CGImage, to url: URL, uti: String, sizes: [Int]) throws {
        let square = squared(image)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, sizes.count, nil) else {
            throw TangeloError.unsupported("This Mac can't write icon files.")
        }
        for s in sizes {
            guard let r = resized(square, width: s, height: s) else { continue }
            CGImageDestinationAddImage(dest, r, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw TangeloError.failed("Couldn't write icon file.") }
    }

    /// Multi-size Windows icon with PNG-compressed entries (supported since Windows Vista).
    static func writeICO(_ image: CGImage, to url: URL, sizes: [Int]) throws {
        let square = squared(image)
        var pngs: [(Int, Data)] = []
        for s in sizes {
            guard let r = resized(square, width: s, height: s) else { continue }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, r, nil)
            guard CGImageDestinationFinalize(dest) else { continue }
            pngs.append((s, data as Data))
        }
        guard !pngs.isEmpty else { throw TangeloError.failed("Couldn't write icon file.") }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var out = Data(le16(0) + le16(1) + le16(pngs.count))
        var offset = 6 + 16 * pngs.count
        for (s, d) in pngs {
            let dim = UInt8(s >= 256 ? 0 : s) // 0 means 256
            out.append(contentsOf: [dim, dim, 0, 0] + le16(1) + le16(32) + le32(d.count) + le32(offset))
            offset += d.count
        }
        for (_, d) in pngs { out.append(d) }
        try out.write(to: url)
    }

    public static func writeGIF(frames: [CGImage], delay: Double, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw TangeloError.failed("Couldn't create GIF.")
        }
        let fileProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay,
                                                                   kCGImagePropertyGIFUnclampedDelayTime as String: delay]]
        for f in frames { CGImageDestinationAddImage(dest, toSRGB(f) ?? f, frameProps as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else { throw TangeloError.failed("Couldn't encode GIF.") }
    }

    // MARK: Pixel helpers

    public static func makeContext(width: Int, height: Int, space: CGColorSpace? = nil, opaque: Bool = false) -> CGContext? {
        let cs = (space?.model == .rgb) ? space! : sRGB
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: cs, bitmapInfo: info)
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    public static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage? {
        guard let ctx = makeContext(width: image.width, height: image.height, space: image.colorSpace, opaque: true) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    public static func toSRGB(_ image: CGImage) -> CGImage? {
        if image.colorSpace?.name == CGColorSpace.sRGB, image.bitsPerComponent == 8 { return image }
        guard let ctx = makeContext(width: image.width, height: image.height, space: sRGB) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = makeContext(width: width, height: height, space: image.colorSpace) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Scales so the longest side is at most `maxSide` (never upscales).
    public static func fitted(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let s = Double(maxSide) / Double(longest)
        return resized(image, width: max(1, Int(Double(image.width) * s)), height: max(1, Int(Double(image.height) * s))) ?? image
    }

    static func squared(_ image: CGImage) -> CGImage {
        guard image.width != image.height else { return image }
        let side = max(image.width, image.height)
        guard let ctx = makeContext(width: side, height: side, space: image.colorSpace) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (side - image.width) / 2, y: (side - image.height) / 2,
                                   width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// RGBA8 (non-premultiplied) pixel buffer in sRGB.
    public static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Un-premultiply.
        var i = 0
        while i < data.count {
            let a = Int(data[i + 3])
            if a > 0 && a < 255 {
                data[i] = UInt8(min(255, (Int(data[i]) * 255 + a / 2) / a))
                data[i + 1] = UInt8(min(255, (Int(data[i + 1]) * 255 + a / 2) / a))
                data[i + 2] = UInt8(min(255, (Int(data[i + 2]) * 255 + a / 2) / a))
            }
            i += 4
        }
        return data
    }

    public static func image(fromRGBA data: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
