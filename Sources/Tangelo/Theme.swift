import Accelerate
import AppKit
import ImageIO
import SwiftUI
import TangeloCore

enum Theme {
    static let tangerine = NSColor(srgbRed: 0.957, green: 0.400, blue: 0.133, alpha: 1)      // #F46622
    static let tangerineDeep = NSColor(srgbRed: 0.890, green: 0.302, blue: 0.094, alpha: 1)  // #E34D18
    static let tangerineLight = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.36, alpha: 1)

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Wedge fill (peach glass in light mode, warm smoked glass in dark mode).
    static func wedge(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.20, green: 0.15, blue: 0.12, alpha: 0.78) : NSColor(srgbRed: 1.0, green: 0.90, blue: 0.81, alpha: 0.86)
    }

    static func wedgeText(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 1.0, green: 0.92, blue: 0.85, alpha: 1) : NSColor(srgbRed: 0.26, green: 0.17, blue: 0.11, alpha: 1)
    }

    static func centerFill(_ dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.96, green: 0.42, blue: 0.15, alpha: 0.30) : NSColor(srgbRed: 0.97, green: 0.47, blue: 0.20, alpha: 0.30)
    }

    static func rim(_ dark: Bool) -> NSColor {
        dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.65)
    }

    static let accent = Color(nsColor: tangerine)
    static let accentDeep = Color(nsColor: tangerineDeep)
}

// MARK: - SwiftUI building blocks shared by the tool windows

/// Orange pill segmented control like the reel's aspect-ratio picker (glass track + sliding glass thumb on macOS 26).
struct PillPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    @Namespace private var thumb

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        let selected = option == selection
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { selection = option }
                        } label: {
                            Text(label(option))
                                .font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(minWidth: 34)
                                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.78))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if selected {
                                Color.clear.glassEffect(.regular.tint(Theme.accent), in: Capsule()).glassEffectID("thumb", in: thumb)
                            }
                        }
                    }
                }
                .padding(3)
                .glassEffect(.regular, in: Capsule())
            }
        } else {
            classic
        }
    }

    private var classic: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(minWidth: 34)
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .background {
                            if selected { Capsule().fill(Theme.accent) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!enabled)
            .keyboardShortcut(.defaultAction)
        } else {
            classic
        }
    }

    private var classic: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Capsule().fill(enabled ? Theme.accent : Color.gray.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}

struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) {
                Text(title).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 2)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        } else {
            classic
        }
    }

    private var classic: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Floating glass container for tool rows (macOS 26), a soft fill before that.
struct GlassBar: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(4).glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.padding(3).background(RoundedRectangle(cornerRadius: cornerRadius - 3).fill(Color.primary.opacity(0.07)))
        }
    }
}

/// Labelled slider row: "Padding ——o—— 160 px".
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "px"
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range).tint(Theme.accent)
            Text("\(format(value))\(unit.isEmpty ? "" : " " + unit)")
                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
        }
    }
}

/// Warm frosted background used by every tool window.
struct ToolBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(colors: [Theme.accent.opacity(0.10), .clear, Color.pink.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}

/// Checkerboard to show transparency behind images.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

// MARK: - Tool window previews

extension PreviewImage {
    /// Loads the preview bitmap for a tool window. Use this rather than `load` for tool previews.
    ///
    /// `ImageKit.load(url, maxPixel:)` makes the preview with `CGImageSourceCreateThumbnailAtIndex`, which draws the decoded
    /// image through CoreGraphics' raster renderer. CoreGraphics keeps a decoded copy of images it draws that way in a
    /// process-wide cache (`ripc_AcquireRIPImageData`: purgeable heap, the last ~32 entries whatever their size) and doesn't
    /// drop the entry when the image is freed. So every tool window open left a preview-sized bitmap (2 MB for 900×600) on
    /// the heap after its window, views and images were gone. Here the image is decoded with `CGImageSourceCreateImageAtIndex`
    /// (subsampled while decoding when possible), then turned upright and scaled with vImage, which never goes through that
    /// cache. The result is premultiplied RGBA8, the layout `ImageKit.makeContext` draws into, so drawing it 1:1 into such a
    /// context needs no converted copy either. Pass `colorSpace` when the preview is drawn into a context of that space.
    static func decode(_ url: URL, maxPixel: Int = 1600, colorSpace: CGColorSpace? = nil) async -> PreviewImage? {
        await Task.detached(priority: .userInitiated) {
            guard let full = ImageKit.pixelSize(of: url), let cg = decodedImage(url, maxPixel: maxPixel, colorSpace: colorSpace) else { return nil }
            return PreviewImage(cg: cg, fullSize: full)
        }.value
    }

    /// `decode` for callers already off the main thread. SVG, HDR, formats vImage can't convert and large images whose
    /// decoder can't subsample fall back to the ImageIO thumbnail.
    static func decodedImage(_ url: URL, maxPixel: Int, colorSpace: CGColorSpace? = nil) -> CGImage? {
        decodedPixels(url, maxPixel: maxPixel, colorSpace: colorSpace) ?? (try? ImageKit.load(url, maxPixel: maxPixel).image)
    }

    /// The preview scaled so its longest side is at most `maxSide` (same size as `ImageKit.fitted`), resampled with vImage
    /// rather than drawn through CoreGraphics, for the same reason as `decode`.
    func fitted(maxSide: Int) -> CGImage {
        let longest = max(cg.width, cg.height)
        guard longest > maxSide else { return cg }
        let s = Double(maxSide) / Double(longest)
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? ImageKit.sRGB
        guard let format = Self.rgba8(space), var pixels = try? vImage_Buffer(cgImage: cg, format: format) else {
            return ImageKit.fitted(cg, maxSide: maxSide)
        }
        defer { pixels.free() }
        guard Self.resample(&pixels, width: max(1, Int(Double(cg.width) * s)), height: max(1, Int(Double(cg.height) * s))),
              let out = try? pixels.createCGImage(format: format) else { return ImageKit.fitted(cg, maxSide: maxSide) }
        return out
    }

    private static func decodedPixels(_ url: URL, maxPixel: Int, colorSpace: CGColorSpace?) -> CGImage? {
        guard url.pathExtension.lowercased() != "svg",
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
        guard let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up

        // Same size as ImageIO's thumbnail: longest side min(maxPixel, longest), the other side rounded.
        let longest = max(w, h), target = max(1, min(maxPixel, longest))
        let s = Double(target) / Double(longest)
        let width = max(1, Int((Double(w) * s).rounded())), height = max(1, Int((Double(h) * s).rounded()))
        // Let the decoder skip pixels (JPEG, HEIF, …) while the result stays at least that big.
        var factor = 1
        while factor < 8, longest / (factor * 2) >= target { factor *= 2 }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let decoded = CGImageSourceCreateImageAtIndex(src, index, options as CFDictionary),
              let space = decoded.colorSpace, !CGColorSpaceUsesITUR_2100TF(space) else { return nil }
        // Some decoders ignore the subsample factor (PSD, GIF, WebP, TGA, BMP…). Converting such an image at full size
        // needs two full-size copies at once (~870 MB for 12000×9000, against ~65 MB for a PSD through the thumbnail
        // path), so leave those to the ImageIO thumbnail fallback, which scales while it decodes.
        if factor > 1, max(decoded.width, decoded.height) >= 2 * target { return nil }

        let keepsSpace = space.model == .rgb && !CGColorSpaceUsesExtendedRange(space)
        guard let format = rgba8(colorSpace ?? (keepsSpace ? space : ImageKit.sRGB)),
              var pixels = try? vImage_Buffer(cgImage: decoded, format: format) else { return nil }
        defer { pixels.free() }
        guard resample(&pixels, width: width, height: height), orient(&pixels, orientation) else { return nil }
        return try? pixels.createCGImage(format: format)
    }

    private static func rgba8(_ space: CGColorSpace) -> vImage_CGImageFormat? {
        vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    /// Replaces `pixels` with a Lanczos resample to `width` × `height`.
    private static func resample(_ pixels: inout vImage_Buffer, width: Int, height: Int) -> Bool {
        if Int(pixels.width) == width && Int(pixels.height) == height { return true }
        guard var out = try? vImage_Buffer(width: width, height: height, bitsPerPixel: 32) else { return false }
        // Lanczos can overshoot at transparent edges; clipping color to alpha keeps the result valid premultiplied RGBA.
        var scaled = out
        guard vImageScale_ARGB8888(&pixels, &out, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImageClipToAlpha_RGBA8888(&scaled, &out, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            out.free(); return false
        }
        pixels.free()
        pixels = out
        return true
    }

    /// Replaces `pixels` with the upright image for an EXIF orientation. (vImage's ARGB8888 geometry ops ignore channel
    /// order, so they work on RGBA.)
    private static func orient(_ pixels: inout vImage_Buffer, _ orientation: CGImagePropertyOrientation) -> Bool {
        if orientation == .up { return true }
        let w = Int(pixels.width), h = Int(pixels.height)
        let quarterTurn = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        guard var out = try? vImage_Buffer(width: quarterTurn ? h : w, height: quarterTurn ? w : h, bitsPerPixel: 32) else { return false }
        var clear: [UInt8] = [0, 0, 0, 0]
        let none = vImage_Flags(kvImageNoFlags)
        var err: vImage_Error = kvImageNoError
        switch orientation {
        case .up: break  // returned above
        case .upMirrored: err = vImageHorizontalReflect_ARGB8888(&pixels, &out, none)
        case .down: err = vImageRotate90_ARGB8888(&pixels, &out, UInt8(kRotate180DegreesClockwise), &clear, none)
        case .downMirrored: err = vImageVerticalReflect_ARGB8888(&pixels, &out, none)
        case .right: err = vImageRotate90_ARGB8888(&pixels, &out, UInt8(kRotate90DegreesClockwise), &clear, none)
        case .left: err = vImageRotate90_ARGB8888(&pixels, &out, UInt8(kRotate90DegreesCounterClockwise), &clear, none)
        case .leftMirrored, .rightMirrored:
            // Transpose / transverse: a clockwise quarter turn, then a horizontal / vertical mirror.
            guard var turned = try? vImage_Buffer(width: h, height: w, bitsPerPixel: 32) else { out.free(); return false }
            defer { turned.free() }
            err = vImageRotate90_ARGB8888(&pixels, &turned, UInt8(kRotate90DegreesClockwise), &clear, none)
            if err == kvImageNoError {
                err = orientation == .leftMirrored ? vImageHorizontalReflect_ARGB8888(&turned, &out, none)
                                                   : vImageVerticalReflect_ARGB8888(&turned, &out, none)
            }
        }
        guard err == kvImageNoError else { out.free(); return false }
        pixels.free()
        pixels = out
        return true
    }
}
