import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum ImageActions {
    static let lossySources: Set<String> = ["jpg", "heic", "heics", "avif", "webp", "jp2"]

    // MARK: Convert

    public static func convert(_ item: InputItem, to format: ImageFormat, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        try ctx.check()
        let dest = ctx.destination(for: item.url, ext: format.ext)
        try await ctx.produce(dest) { tmp in
            if format == .webp {
                try WebP.write(loaded.image, to: tmp, quality: ctx.settings.quality,
                               lossless: !lossySources.contains(item.format), settings: ctx.settings)
            } else {
                try ImageKit.write(loaded.image, to: tmp, format: format, quality: ctx.settings.quality,
                                   properties: loaded.properties, settings: ctx.settings)
            }
        }
    }

    /// Keeps the user's spelling ("jpeg", "JPG", "tif") when the format doesn't change.
    static func extensionKeepingOriginal(_ item: InputItem, _ format: ImageFormat) -> String {
        let ext = item.url.pathExtension
        return ImageFormat(formatKey: item.format) == format && !ext.isEmpty ? ext : format.ext
    }

    /// Writes `image` in the item's own format when possible (PNG otherwise).
    static func writeSameFormat(_ image: CGImage, like item: InputItem, suffix: String, loaded: LoadedImage?,
                                quality: Double? = nil, ctx: JobContext) async throws {
        var format = ImageFormat(formatKey: item.format) ?? .png
        if [.ico, .icns, .pdf, .gif].contains(format) { format = .png }
        let dest = ctx.destination(for: item.url, ext: extensionKeepingOriginal(item, format), suffix: suffix)
        try await ctx.produce(dest) { tmp in
            if format == .webp {
                try WebP.write(image, to: tmp, quality: quality ?? ctx.settings.quality,
                               lossless: !lossySources.contains(item.format), settings: ctx.settings)
            } else {
                try ImageKit.write(image, to: tmp, format: format, quality: quality ?? max(ctx.settings.quality, 0.9),
                                   properties: loaded?.properties, settings: ctx.settings)
            }
        }
    }

    // MARK: Compress

    public static func compress(_ item: InputItem, level: CompressLevel, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        var img = loaded.image
        switch level {
        case .light: break
        case .balanced: img = ImageKit.fitted(img, maxSide: 4096)
        case .strong: img = ImageKit.fitted(img, maxSide: 2560)
        }
        let quality: Double = level == .light ? 0.8 : (level == .balanced ? 0.65 : 0.5)
        var format = ImageFormat(formatKey: item.format) ?? .jpg
        if [.bmp, .tga, .psd, .ico, .icns, .gif, .pdf].contains(format) { format = .png }
        let dest = ctx.destination(for: item.url, ext: extensionKeepingOriginal(item, format), suffix: "Compressed")
        let out = try await ctx.produce(dest) { tmp in
            switch format {
            case .png:
                let colors = level == .strong ? 128 : 256
                guard let data = PNGQuant.encode(img, maxColors: colors, dither: level == .light ? 0.6 : 0.85) else {
                    throw TangeloError.failed("Couldn't compress this PNG.")
                }
                try data.write(to: tmp)
            case .tiff:
                try writeTIFF(img, to: tmp, properties: loaded.properties, settings: ctx.settings)
            case .webp:
                try WebP.write(img, to: tmp, quality: quality, lossless: false, settings: ctx.settings)
            default:
                try ImageKit.write(img, to: tmp, format: format, quality: quality, properties: loaded.properties,
                                   settings: ctx.settings)
            }
        }
        try reportSavings(original: item, output: out, ctx: ctx)
    }

    /// Removes outputs that came out bigger and explains; otherwise records "1.2 MB → 300 KB".
    static func reportSavings(original: InputItem, output: URL, ctx: JobContext) throws {
        let before = original.size > 0 ? original.size : ByteFormat.size(of: original.url)
        let after = ByteFormat.size(of: output)
        if before > 0 && Double(after) > Double(before) * 0.98 {
            try? FileManager.default.removeItem(at: output)
            ctx.remove(output: output)
            throw TangeloError.failed("\(original.url.lastPathComponent) is already as small as it gets.")
        }
        ctx.summary = ByteFormat.savings(from: before, to: after)
    }

    static func writeTIFF(_ image: CGImage, to url: URL, properties: [String: Any]?, settings: EngineSettings) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
            throw TangeloError.failed("Couldn't write TIFF.")
        }
        var props = ImageKit.metadata(from: properties, keepLocation: settings.keepLocation)
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression as String] = 5 // LZW
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TangeloError.failed("Couldn't write TIFF.") }
    }

    // MARK: Geometry

    public static func resize(_ item: InputItem, width: Int, height: Int, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        guard let img = ImageKit.resized(loaded.image, width: width, height: height) else {
            throw TangeloError.failed("Couldn't resize.")
        }
        try await writeSameFormat(img, like: item, suffix: "\(width)×\(height)", loaded: loaded, ctx: ctx)
    }

    public static func resize(_ item: InputItem, scale: Double, ctx: JobContext) async throws {
        guard let size = ImageKit.pixelSize(of: item.url) else { throw TangeloError.failed("Couldn't read image size.") }
        try await resize(item, width: max(1, Int((size.width * scale).rounded())),
                         height: max(1, Int((size.height * scale).rounded())), ctx: ctx)
    }

    public static func crop(_ item: InputItem, rect: CGRect, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        let bounds = CGRect(x: 0, y: 0, width: loaded.width, height: loaded.height)
        let r = rect.integral.intersection(bounds)
        guard !r.isEmpty, let img = loaded.image.cropping(to: r) else { throw TangeloError.failed("Invalid crop area.") }
        try await writeSameFormat(img, like: item, suffix: "Cropped", loaded: loaded, ctx: ctx)
    }

    /// `quarterTurns` clockwise.
    public static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let q = ((quarterTurns % 4) + 4) % 4
        if q == 0 { return image }
        let w = image.width, h = image.height
        let (ow, oh) = q % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = ImageKit.makeContext(width: ow, height: oh, space: image.colorSpace) else { return nil }
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    public static func flip(_ image: CGImage, horizontal: Bool) -> CGImage? {
        guard let ctx = ImageKit.makeContext(width: image.width, height: image.height, space: image.colorSpace) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(image.width), y: 0); ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    public static func rotate(_ item: InputItem, quarterTurns: Int, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        guard let img = rotate(loaded.image, quarterTurns: quarterTurns) else { throw TangeloError.failed("Couldn't rotate.") }
        try await writeSameFormat(img, like: item, suffix: "Rotated", loaded: loaded, ctx: ctx)
    }

    public static func flip(_ item: InputItem, horizontal: Bool, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        guard let img = flip(loaded.image, horizontal: horizontal) else { throw TangeloError.failed("Couldn't flip.") }
        try await writeSameFormat(img, like: item, suffix: "Flipped", loaded: loaded, ctx: ctx)
    }

    public static func grayscale(_ item: InputItem, ctx: JobContext) async throws {
        let loaded = try ImageKit.load(item.url)
        let ci = CIImage(cgImage: loaded.image).applyingFilter("CIPhotoEffectMono")
        guard let img = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageKit.sRGB) else {
            throw TangeloError.failed("Couldn't convert to grayscale.")
        }
        try await writeSameFormat(img, like: item, suffix: "Grayscale", loaded: loaded, ctx: ctx)
    }

    // MARK: Multiple images

    public static func combineToPDF(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        let dest = ctx.destination(named: first.baseName + " Combined", ext: "pdf", near: first.url)
        try await ctx.produce(dest) { tmp in
            guard let consumer = CGDataConsumer(url: tmp as CFURL),
                  let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw TangeloError.failed("Couldn't create PDF.") }
            for (i, item) in items.enumerated() {
                try ctx.check()
                ctx.report(Double(i) / Double(items.count), "\(i + 1) of \(items.count)")
                if item.kind == .pdf, let doc = CGPDFDocument(item.url as CFURL) {
                    for p in 1...max(doc.numberOfPages, 1) {
                        guard let page = doc.page(at: p) else { continue }
                        var box = page.getBoxRect(.cropBox)
                        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                        pdf.beginPDFPage(info)
                        pdf.drawPDFPage(page)
                        pdf.endPDFPage()
                    }
                    continue
                }
                let loaded = try ImageKit.load(item.url)
                let dpi = ImageKit.dpi(loaded.properties)
                var box = CGRect(x: 0, y: 0, width: Double(loaded.width) * 72 / dpi, height: Double(loaded.height) * 72 / dpi)
                let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                pdf.beginPDFPage(info)
                pdf.interpolationQuality = .high
                pdf.draw(loaded.image, in: box)
                pdf.endPDFPage()
            }
            pdf.closePDF()
        }
    }

    public static func animatedGIF(_ items: [InputItem], frameDelay: Double = 0.5, ctx: JobContext) async throws {
        guard let first = items.first else { return }
        let base = ImageKit.fitted(try ImageKit.load(first.url).image, maxSide: 1200)
        let w = base.width, h = base.height
        var frames: [CGImage] = []
        for item in items {
            try ctx.check()
            let img = try ImageKit.load(item.url, maxPixel: 1200).image
            guard let c = ImageKit.makeContext(width: w, height: h) else { continue }
            c.setFillColor(CGColor(gray: 1, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let s = min(Double(w) / Double(img.width), Double(h) / Double(img.height))
            let dw = Double(img.width) * s, dh = Double(img.height) * s
            c.interpolationQuality = .high
            c.draw(img, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
            if let f = c.makeImage() { frames.append(f) }
        }
        let dest = ctx.destination(named: first.baseName + " Animated", ext: "gif", near: first.url)
        try await ctx.produce(dest) { tmp in try ImageKit.writeGIF(frames: frames, delay: frameDelay, to: tmp) }
    }

    public static func stitch(_ items: [InputItem], vertical: Bool, ctx: JobContext) async throws {
        guard let first = items.first else { return }
        let images = try items.map { try ImageKit.load($0.url).image }
        let target = vertical ? images.map(\.width).min()! : images.map(\.height).min()!
        let scaled = images.map { img -> CGImage in
            let s = Double(target) / Double(vertical ? img.width : img.height)
            guard abs(s - 1) > 0.001 else { return img }
            return ImageKit.resized(img, width: max(1, Int(Double(img.width) * s)), height: max(1, Int(Double(img.height) * s))) ?? img
        }
        let W = vertical ? target : scaled.reduce(0) { $0 + $1.width }
        let H = vertical ? scaled.reduce(0) { $0 + $1.height } : target
        guard W * H < 400_000_000, let c = ImageKit.makeContext(width: W, height: H) else {
            throw TangeloError.failed("The stitched image would be too large.")
        }
        var offset = 0
        for img in scaled {
            if vertical {
                c.draw(img, in: CGRect(x: 0, y: H - offset - img.height, width: img.width, height: img.height))
                offset += img.height
            } else {
                c.draw(img, in: CGRect(x: offset, y: 0, width: img.width, height: img.height))
                offset += img.width
            }
        }
        guard let out = c.makeImage() else { throw TangeloError.failed("Couldn't stitch images.") }
        let allJPEG = items.allSatisfy { $0.format == "jpg" }
        let format: ImageFormat = allJPEG ? .jpg : .png
        let dest = ctx.destination(named: first.baseName + " Stitched", ext: format.ext, near: first.url)
        try await ctx.produce(dest) { tmp in
            try ImageKit.write(out, to: tmp, format: format, quality: 0.9, settings: ctx.settings)
        }
    }
}
