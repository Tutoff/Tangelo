import Compression
import CoreGraphics
import Foundation

/// Palette (8-bit) PNG writer with median-cut quantization + dithering.
/// Gives pngquant-style size reductions for screenshots and graphics, fully offline.
public enum PNGQuant {
    /// Returns PNG data, or nil if quantization isn't possible.
    public static func encode(_ image: CGImage, maxColors: Int = 256, dither: Double = 0.85) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let rgba = ImageKit.rgbaPixels(image) else { return nil }
        let palette: [SIMD4<Float>]
        let exact = exactPalette(rgba, limit: maxColors)
        if let exact { palette = exact } else { palette = medianCut(rgba, colors: maxColors) }
        let indices = map(rgba, width: w, height: h, palette: palette, dither: exact == nil ? Float(dither) : 0)
        return writePNG(width: w, height: h, palette: palette, indices: indices)
    }

    // MARK: Palette

    static func exactPalette(_ rgba: [UInt8], limit: Int) -> [SIMD4<Float>]? {
        var seen = Set<UInt32>()
        var i = 0
        while i < rgba.count {
            var c = UInt32(rgba[i]) << 24 | UInt32(rgba[i + 1]) << 16 | UInt32(rgba[i + 2]) << 8 | UInt32(rgba[i + 3])
            if rgba[i + 3] == 0 { c = 0 }
            if seen.insert(c).inserted && seen.count > limit { return nil }
            i += 4
        }
        return seen.sorted().map {
            SIMD4(Float($0 >> 24), Float(($0 >> 16) & 0xFF), Float(($0 >> 8) & 0xFF), Float($0 & 0xFF))
        }
    }

    private struct Bin { var count: Float; var sum: SIMD4<Float>; var key: SIMD4<Float> }

    static func medianCut(_ rgba: [UInt8], colors: Int) -> [SIMD4<Float>] {
        // Histogram on 5 bits per channel.
        var counts = [Double](repeating: 0, count: 1 << 20)
        var sums = [SIMD4<Double>](repeating: .zero, count: 1 << 20)
        var i = 0
        while i < rgba.count {
            let a = rgba[i + 3]
            let r = a == 0 ? 0 : rgba[i], g = a == 0 ? 0 : rgba[i + 1], b = a == 0 ? 0 : rgba[i + 2]
            let k = Int(r >> 3) << 15 | Int(g >> 3) << 10 | Int(b >> 3) << 5 | Int(a >> 3)
            counts[k] += 1
            sums[k] += SIMD4(Double(r), Double(g), Double(b), Double(a))
            i += 4
        }
        var bins: [Bin] = []
        for k in 0..<counts.count where counts[k] > 0 {
            let m = sums[k] / counts[k]
            let mean = SIMD4<Float>(Float(m.x), Float(m.y), Float(m.z), Float(m.w))
            bins.append(Bin(count: Float(counts[k]), sum: mean * Float(counts[k]), key: mean))
        }
        if bins.count <= colors { return bins.map { $0.sum / $0.count } }

        // Boxes are ranges into `bins`.
        var boxes: [Range<Int>] = [0..<bins.count]
        func stats(_ r: Range<Int>) -> (axis: Int, score: Float) {
            var lo = SIMD4<Float>(repeating: 999), hi = SIMD4<Float>(repeating: -1), n: Float = 0
            for j in r { lo = pointwiseMin(lo, bins[j].key); hi = pointwiseMax(hi, bins[j].key); n += bins[j].count }
            var span = hi - lo
            span[3] *= 1.5 // alpha differences are very visible
            var axis = 0
            for a in 1..<4 where span[a] > span[axis] { axis = a }
            return (axis, span[axis] * sqrt(n))
        }
        while boxes.count < colors {
            var best = -1, bestScore: Float = 0, bestAxis = 0
            for (bi, r) in boxes.enumerated() where r.count > 1 {
                let s = stats(r)
                if s.score > bestScore { bestScore = s.score; best = bi; bestAxis = s.axis }
            }
            if best < 0 { break }
            let r = boxes[best]
            bins[r].sort { $0.key[bestAxis] < $1.key[bestAxis] }
            let total = bins[r].reduce(Float(0)) { $0 + $1.count }
            var acc: Float = 0, cut = r.lowerBound + 1
            for j in r {
                acc += bins[j].count
                if acc >= total / 2 { cut = min(max(j + 1, r.lowerBound + 1), r.upperBound - 1); break }
            }
            boxes[best] = r.lowerBound..<cut
            boxes.append(cut..<r.upperBound)
        }
        var palette = boxes.map { r -> SIMD4<Float> in
            var s = SIMD4<Float>.zero, n: Float = 0
            for j in r { s += bins[j].sum; n += bins[j].count }
            return s / max(n, 1)
        }
        // A few k-means passes over the histogram.
        for _ in 0..<3 {
            var sum = [SIMD4<Float>](repeating: .zero, count: palette.count)
            var cnt = [Float](repeating: 0, count: palette.count)
            for b in bins {
                let p = nearest(b.key, palette)
                sum[p] += b.sum
                cnt[p] += b.count
            }
            for p in palette.indices where cnt[p] > 0 { palette[p] = sum[p] / cnt[p] }
        }
        return palette.map { $0.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255)) }
    }

    @inline(__always) static func nearest(_ c: SIMD4<Float>, _ palette: [SIMD4<Float>]) -> Int {
        var best = 0, bestD = Float.greatestFiniteMagnitude
        for (i, p) in palette.enumerated() {
            var d = c - p
            d[3] *= 1.5
            let dist = (d * d).sum()
            if dist < bestD { bestD = dist; best = i }
        }
        return best
    }

    static func map(_ rgba: [UInt8], width: Int, height: Int, palette: [SIMD4<Float>], dither: Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var cache = [Int16](repeating: -1, count: 1 << 20)
        var errCur = [SIMD4<Float>](repeating: .zero, count: width + 2)
        var errNext = [SIMD4<Float>](repeating: .zero, count: width + 2)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var c = SIMD4(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]), Float(rgba[i + 3]))
                if c[3] == 0 { c = .zero }
                if dither > 0 && c[3] > 0 { c += errCur[x + 1] * dither }
                c = c.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255))
                let k = ((Int(c[0]) >> 3) << 15) | ((Int(c[1]) >> 3) << 10) | ((Int(c[2]) >> 3) << 5) | (Int(c[3]) >> 3)
                var idx = Int(cache[k])
                if idx < 0 { idx = nearest(c, palette); cache[k] = Int16(idx) }
                out[y * width + x] = UInt8(idx)
                if dither > 0 {
                    let e = c - palette[idx]
                    errCur[x + 2] += e * (7.0 / 16)
                    errNext[x] += e * (3.0 / 16)
                    errNext[x + 1] += e * (5.0 / 16)
                    errNext[x + 2] += e * (1.0 / 16)
                }
            }
            if dither > 0 {
                swap(&errCur, &errNext)
                for j in errNext.indices { errNext[j] = .zero }
            }
        }
        return out
    }

    // MARK: PNG writing

    static func writePNG(width: Int, height: Int, palette: [SIMD4<Float>], indices: [UInt8]) -> Data? {
        var raw = Data(capacity: (width + 1) * height)
        for y in 0..<height {
            raw.append(0) // filter: none (best for indexed images)
            raw.append(contentsOf: indices[(y * width)..<((y + 1) * width)])
        }
        guard let deflated = deflate(raw) else { return nil }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(UInt32(width))); ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [8, 3, 0, 0, 0])
        png.append(chunk("IHDR", ihdr))
        var plte = Data(), trns = Data()
        for p in palette {
            func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
            plte.append(contentsOf: [byte(p[0]), byte(p[1]), byte(p[2])])
            trns.append(byte(p[3]))
        }
        png.append(chunk("PLTE", plte))
        while let last = trns.last, last == 255 { trns.removeLast() }
        if !trns.isEmpty { png.append(chunk("tRNS", trns)) }
        var z = Data([0x78, 0xDA])
        z.append(deflated)
        z.append(be32(adler32(raw)))
        png.append(chunk("IDAT", z))
        png.append(chunk("IEND", Data()))
        return png
    }

    static func deflate(_ input: Data) -> Data? {
        let capacity = input.count + input.count / 8 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    static func chunk(_ type: String, _ data: Data) -> Data {
        var c = Data()
        c.append(be32(UInt32(data.count)))
        let typed = Data(type.utf8) + data
        c.append(typed)
        c.append(be32(crc32(typed)))
        return c
    }

    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var processed = 0
        data.withUnsafeBytes { buf in
            let p = buf.bindMemory(to: UInt8.self)
            while processed < p.count {
                let end = min(processed + 5552, p.count)
                for i in processed..<end { a += UInt32(p[i]); b += a }
                a %= 65521; b %= 65521
                processed = end
            }
        }
        return (b << 16) | a
    }
}
