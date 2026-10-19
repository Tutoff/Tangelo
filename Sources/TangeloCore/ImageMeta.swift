import CoreGraphics
import Foundation
import ImageIO

/// Reading and removing image metadata (EXIF, GPS, camera info).
public enum ImageMeta {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let group: String
        public let key: String
        public let value: String
    }

    public struct Location: Sendable {
        public let latitude: Double
        public let longitude: Double
    }

    static let groupNames: [String: String] = [
        kCGImagePropertyExifDictionary as String: "Camera",
        kCGImagePropertyTIFFDictionary as String: "Image",
        kCGImagePropertyGPSDictionary as String: "Location",
        kCGImagePropertyIPTCDictionary as String: "IPTC",
        kCGImagePropertyExifAuxDictionary as String: "Lens",
        kCGImagePropertyPNGDictionary as String: "PNG",
        kCGImagePropertyJFIFDictionary as String: "JFIF",
        kCGImagePropertyHEIFDictionary as String: "HEIF",
        kCGImagePropertyGIFDictionary as String: "GIF",
        "{MakerApple}": "Apple",
    ]

    public static func properties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [String: Any] ?? [:]
    }

    public static func entries(for url: URL) -> [Entry] {
        let props = properties(url)
        var out: [Entry] = []
        let general: [(String, String)] = [
            (kCGImagePropertyPixelWidth as String, "Width"), (kCGImagePropertyPixelHeight as String, "Height"),
            (kCGImagePropertyDPIWidth as String, "DPI"), (kCGImagePropertyColorModel as String, "Color Model"),
            (kCGImagePropertyDepth as String, "Bit Depth"), (kCGImagePropertyProfileName as String, "Color Profile"),
            (kCGImagePropertyOrientation as String, "Orientation"), (kCGImagePropertyHasAlpha as String, "Transparency"),
        ]
        out.append(Entry(group: "File", key: "Size", value: ByteFormat.string(ByteFormat.size(of: url))))
        for (k, title) in general {
            if let v = props[k] { out.append(Entry(group: "File", key: title, value: format(v))) }
        }
        let preferred = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
                         kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary].map { $0 as String }
        let groups = preferred + props.keys.filter { $0.hasPrefix("{") && !preferred.contains($0) }.sorted()
        for g in groups {
            guard let dict = props[g] as? [String: Any], !dict.isEmpty else { continue }
            let name = groupNames[g] ?? g.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            for k in dict.keys.sorted() {
                let v = format(dict[k]!)
                if v.isEmpty || v.count > 300 { continue }
                out.append(Entry(group: name, key: humanize(k), value: v))
            }
        }
        return out
    }

    public static func location(for url: URL) -> Location? {
        guard let gps = properties(url)[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              var lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" { lon = -lon }
        return Location(latitude: lat, longitude: lon)
    }

    static func format(_ v: Any) -> String {
        switch v {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "Yes" : "No" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(format: "%.4g", d)
        case let a as [Any]: return a.map(format).joined(separator: ", ")
        case is [String: Any]: return ""
        default: return "\(v)"
        }
    }

    /// "ISOSpeedRatings" → "ISO Speed Ratings", "PixelXDimension" → "Pixel X Dimension".
    static func humanize(_ key: String) -> String {
        let chars = Array(key)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let prev = chars[i - 1]
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextLower) { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }

    /// Writes a copy without metadata. JPEG/PNG/TIFF are copied losslessly; orientation is kept so the photo stays upright.
    public static func strip(_ item: InputItem, onlyLocation: Bool = false, ctx: JobContext) async throws {
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw TangeloError.unsupported("Couldn't read \(item.url.lastPathComponent).")
        }
        let props = properties(item.url)
        let dest = ctx.destination(for: item.url, ext: item.url.pathExtension.isEmpty ? "jpg" : item.url.pathExtension,
                                   suffix: onlyLocation ? "No Location" : "Clean")
        try await ctx.produce(dest) { tmp in
            guard let d = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { throw TangeloError.failed("Couldn't write the image.") }
            var opts: [CFString: Any]
            if onlyLocation {
                opts = [kCGImageMetadataShouldExcludeGPS: true]
            } else {
                let meta = CGImageMetadataCreateMutable()
                if let o = props[kCGImagePropertyOrientation as String] as? Int, o != 1 {
                    CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o as CFNumber)
                }
                opts = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false, kCGImageMetadataShouldExcludeGPS: true]
            }
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(d, src, opts as CFDictionary, &error) {
                // Some formats (HEIC) ignore the exclusion options; only accept the lossless copy if it really is clean.
                let p = properties(tmp)
                let clean = onlyLocation ? p[kCGImagePropertyGPSDictionary as String] == nil
                    : (p[kCGImagePropertyGPSDictionary as String] == nil && p[kCGImagePropertyExifDictionary as String].map { ($0 as? [String: Any])?.count ?? 0 <= 4 } ?? true)
                if clean { return }
            }
            // Formats that can't be copied losslessly: re-encode without metadata.
            let loaded = try ImageKit.load(item.url)
            var settings = ctx.settings
            settings.keepLocation = onlyLocation ? false : settings.keepLocation
            let fmt = ImageFormat(formatKey: item.format) ?? .png
            let keep: [String: Any]? = onlyLocation ? loaded.properties : nil
            try? FileManager.default.removeItem(at: tmp)
            try ImageKit.write(loaded.image, to: tmp, format: fmt, quality: 0.95, properties: keep, settings: settings)
        }
    }
}
