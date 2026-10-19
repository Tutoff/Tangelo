import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import TangeloCore

/// Measurements used by the QA suite to check that results are *correct*, not just present.
enum Probe {
    // MARK: Images

    struct ImageInfo {
        let width: Int, height: Int
        let uti: String
        let frames: Int
        let orientation: Int
        let hasGPS: Bool
        let hasLens: Bool
    }

    static func image(_ url: URL) -> ImageInfo? {
        if url.pathExtension.lowercased() == "svg" {
            // ImageIO can't read SVG; measure Tangelo's own rasterization instead.
            guard let img = try? ImageKit.load(url).image else { return nil }
            return ImageInfo(width: img.width, height: img.height, uti: "public.svg-image", frames: 1, orientation: 1, hasGPS: false, hasLens: false)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let p = CGImageSourceCopyPropertiesAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) as? [String: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let o = p[kCGImagePropertyOrientation as String] as? Int ?? 1
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        return ImageInfo(width: o >= 5 ? h : w, height: o >= 5 ? w : h, uti: CGImageSourceGetType(src) as String? ?? "?",
                         frames: CGImageSourceGetCount(src), orientation: o,
                         hasGPS: p[kCGImagePropertyGPSDictionary as String] != nil,
                         hasLens: exif[kCGImagePropertyExifLensModel as String] != nil)
    }

    /// Upright image squeezed to size×size, RGB 0...1 composited on white (aspect ignored on purpose:
    /// rotating/flipping a squeezed thumbnail equals squeezing the rotated/flipped image).
    static func thumb(_ cg: CGImage, size: Int = 32) -> [Float] {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: ImageKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        var out = [Float](repeating: 0, count: size * size * 3)
        for i in 0..<(size * size) {
            out[i * 3] = Float(px[i * 4]) / 255; out[i * 3 + 1] = Float(px[i * 4 + 1]) / 255; out[i * 3 + 2] = Float(px[i * 4 + 2]) / 255
        }
        return out
    }

    static func thumb(_ url: URL, size: Int = 32) -> [Float]? {
        guard let img = try? ImageKit.load(url, maxPixel: 512).image else { return nil }
        return thumb(img, size: size)
    }

    /// Clockwise quarter turns of a square RGB thumbnail.
    static func rotate(_ t: [Float], size s: Int, quarterTurns: Int) -> [Float] {
        var cur = t
        for _ in 0..<(((quarterTurns % 4) + 4) % 4) {
            var out = [Float](repeating: 0, count: cur.count)
            for r in 0..<s { for c in 0..<s {
                // new[r][c] = old[s-1-c][r]
                let src = ((s - 1 - c) * s + r) * 3, dst = (r * s + c) * 3
                out[dst] = cur[src]; out[dst + 1] = cur[src + 1]; out[dst + 2] = cur[src + 2]
            } }
            cur = out
        }
        return cur
    }

    static func flip(_ t: [Float], size s: Int, horizontal: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: t.count)
        for r in 0..<s { for c in 0..<s {
            let src = horizontal ? (r * s + (s - 1 - c)) * 3 : ((s - 1 - r) * s + c) * 3
            let dst = (r * s + c) * 3
            out[dst] = t[src]; out[dst + 1] = t[src + 1]; out[dst + 2] = t[src + 2]
        } }
        return out
    }

    static func diff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var s: Float = 0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }

    static func saturation(_ t: [Float]) -> Float {
        var s: Float = 0
        for i in stride(from: 0, to: t.count, by: 3) { s += max(t[i], t[i + 1], t[i + 2]) - min(t[i], t[i + 1], t[i + 2]) }
        return s / Float(t.count / 3)
    }

    /// Fraction of fully transparent / fully opaque pixels.
    static func alphaStats(_ url: URL) -> (transparent: Double, opaque: Double)? {
        guard let img = try? ImageKit.load(url, maxPixel: 256).image, let px = ImageKit.rgbaPixels(img) else { return nil }
        var t = 0, o = 0
        for i in stride(from: 3, to: px.count, by: 4) { if px[i] == 0 { t += 1 } else if px[i] == 255 { o += 1 } }
        let n = Double(px.count / 4)
        return (Double(t) / n, Double(o) / n)
    }

    // MARK: PDF

    struct PDFInfo { let pages: Int; let rotations: [Int]; let text: String; let encrypted: Bool; let firstPageSize: CGSize }

    static func pdf(_ url: URL) -> PDFInfo? {
        guard let d = PDFDocument(url: url) else { return nil }
        var rot: [Int] = []
        for i in 0..<d.pageCount { rot.append(d.page(at: i)?.rotation ?? -1) }
        return PDFInfo(pages: d.pageCount, rotations: rot, text: d.isLocked ? "" : (d.string ?? ""), encrypted: d.isEncrypted,
                       firstPageSize: d.page(at: 0)?.bounds(for: .cropBox).size ?? .zero)
    }

    // MARK: Media (ffprobe)

    struct Media {
        var duration: Double = 0
        var videoCodec: String?
        var audioCodec: String?
        var width = 0, height = 0       // as displayed (rotation applied)
        var channels = 0
        var frames = 0
    }

    static func media(_ url: URL) async -> Media? {
        guard let ffmpeg = ExternalTools.find("ffmpeg") else { return nil }
        let ffprobe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard let r = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]),
              r.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] else { return nil }
        var m = Media()
        if let f = json["format"] as? [String: Any], let d = Double(f["duration"] as? String ?? "") { m.duration = d }
        // Raw ADTS AAC has no duration header (ffprobe guesses from bitrate): count packets instead.
        if url.pathExtension.lowercased() == "aac",
           let c = try? await ProcessRunner.run(ffprobe, ["-v", "error", "-count_packets", "-select_streams", "a:0",
                                                          "-show_entries", "stream=nb_read_packets,sample_rate", "-of", "csv=p=0", url.path]) {
            let parts = c.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0 { m.duration = parts[1] * 1024 / parts[0] }
        }
        for s in json["streams"] as? [[String: Any]] ?? [] {
            let type = s["codec_type"] as? String
            if type == "video", m.videoCodec == nil {
                m.videoCodec = s["codec_name"] as? String
                var w = s["width"] as? Int ?? 0, h = s["height"] as? Int ?? 0
                var rotation = 0
                for sd in s["side_data_list"] as? [[String: Any]] ?? [] { if let r = sd["rotation"] as? Int { rotation = r } else if let r = sd["rotation"] as? Double { rotation = Int(r) } }
                if let tags = s["tags"] as? [String: Any], let r = Int(tags["rotate"] as? String ?? "") { rotation = r }
                if abs(rotation) % 180 == 90 { swap(&w, &h) }
                m.width = w; m.height = h
                m.frames = Int(s["nb_frames"] as? String ?? "") ?? 0
                if m.duration == 0, let d = Double(s["duration"] as? String ?? "") { m.duration = d }
            } else if type == "audio", m.audioCodec == nil {
                m.audioCodec = s["codec_name"] as? String
                m.channels = s["channels"] as? Int ?? 0
                if m.duration == 0, let d = Double(s["duration"] as? String ?? "") { m.duration = d }
            }
        }
        return m
    }

    /// A frame as displayed (track transform applied).
    static func frame(_ url: URL, at seconds: Double = 1) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Audio samples

    struct AudioInfo { let peak: Float; let channels: Int; let envelope: [Float] }

    static func audio(_ url: URL) -> AudioInfo? {
        guard let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(min(f.length, 48_000 * 60))) else { return nil }
        try? f.read(into: buf)
        guard let data = buf.floatChannelData, buf.frameLength > 0 else { return nil }
        let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
        var peak: Float = 0
        var env = [Float](repeating: 0, count: 10)
        for c in 0..<ch {
            for i in 0..<n {
                let v = abs(data[c][i])
                peak = max(peak, v)
                env[min(9, i * 10 / n)] += v * v
            }
        }
        return AudioInfo(peak: peak, channels: ch, envelope: env.map { sqrt($0 / Float(max(1, n * ch / 10))) })
    }

    // MARK: Text

    static func text(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return pdf(url)?.text ?? ""
        case "txt", "md", "csv", "tsv", "json", "html": return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        default: return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string) ?? ""
        }
    }

    static func listing(_ url: URL) async -> String {
        let r: ProcessRunner.Result?
        if url.pathExtension.lowercased() == "zip" { r = try? await ProcessRunner.run("/usr/bin/unzip", ["-l", url.path]) }
        else { r = try? await ProcessRunner.run("/usr/bin/tar", ["-tzf", url.path]) }
        return r?.stdout ?? ""
    }
}
