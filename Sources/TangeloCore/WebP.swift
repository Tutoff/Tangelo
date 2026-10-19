import CoreGraphics
import Foundation
import ImageIO

/// WebP output. macOS can read WebP but not write it, so Tangelo ships its own
/// lossless (VP8L) encoder, and uses `cwebp` for smaller lossy files when it is installed.
public enum WebP {
    public static func write(_ image: CGImage, to url: URL, quality: Double, lossless: Bool = false,
                             settings: EngineSettings) throws {
        if let cwebp = settings.cwebpPath {
            try writeWithCWebP(image, to: url, quality: quality, lossless: lossless, tool: cwebp)
            return
        }
        guard image.width <= 16383, image.height <= 16383 else {
            throw TangeloError.unsupported("WebP images can be at most 16383 pixels per side.")
        }
        guard let rgba = ImageKit.rgbaPixels(image) else { throw TangeloError.failed("Couldn't read pixels.") }
        let data = VP8LEncoder.encode(rgba: rgba, width: image.width, height: image.height)
        try data.write(to: url)
    }

    static func writeWithCWebP(_ image: CGImage, to url: URL, quality: Double, lossless: Bool, tool: String) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tangelo-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else {
            throw TangeloError.failed("Couldn't prepare image for cwebp.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TangeloError.failed("Couldn't prepare image for cwebp.") }
        var args = ["-quiet", "-mt", "-m", "4", "-metadata", "icc"]
        args += lossless ? ["-lossless", "-q", "75"] : ["-q", String(Int((quality * 100).rounded()))]
        args += [tmp.path, "-o", url.path]
        guard try ProcessRunner.runAndWait(tool, args) == 0 else { throw TangeloError.failed("cwebp couldn't encode the image.") }
    }
}

// MARK: - VP8L (lossless WebP) encoder

enum VP8LEncoder {
    static func encode(rgba: [UInt8], width: Int, height: Int) -> Data {
        let n = width * height
        var argb = [UInt32](repeating: 0, count: n)
        var hasAlpha = false
        rgba.withUnsafeBufferPointer { src in
            for i in 0..<n {
                let r = UInt32(src[i * 4]), g = UInt32(src[i * 4 + 1]), b = UInt32(src[i * 4 + 2]), a = UInt32(src[i * 4 + 3])
                if a != 255 { hasAlpha = true }
                argb[i] = (a << 24) | (r << 16) | (g << 8) | b
            }
        }

        var w = BitWriter()
        w.write(0x2F, 8)
        w.write(UInt32(width - 1), 14)
        w.write(UInt32(height - 1), 14)
        w.write(hasAlpha ? 1 : 0, 1)
        w.write(0, 3)

        var pixels: [UInt32]
        var xsize = width
        var cacheBits = 10

        if let palette = palette(of: argb, limit: 256) {
            // Color-indexing transform.
            w.write(1, 1); w.write(3, 2)
            w.write(UInt32(palette.count - 1), 8)
            var deltas = palette
            for i in stride(from: palette.count - 1, to: 0, by: -1) { deltas[i] = subPixels(palette[i], palette[i - 1]) }
            writeImage(deltas, width: palette.count, cacheBits: 0, isMain: false, to: &w)

            var index = [UInt32: UInt32]()
            for (i, c) in palette.enumerated() { index[c] = UInt32(i) }
            let widthBits = palette.count <= 2 ? 3 : palette.count <= 4 ? 2 : palette.count <= 16 ? 1 : 0
            let perPixel = 1 << widthBits
            let bitsPerPixel = 8 >> widthBits
            xsize = (width + perPixel - 1) / perPixel
            pixels = [UInt32](repeating: 0, count: xsize * height)
            for y in 0..<height {
                for xp in 0..<xsize {
                    var code: UInt32 = 0
                    for k in 0..<perPixel {
                        let x = xp * perPixel + k
                        if x < width { code |= index[argb[y * width + x]]! << UInt32(k * bitsPerPixel) }
                    }
                    pixels[y * xsize + xp] = 0xFF00_0000 | (code << 8)
                }
            }
            cacheBits = 0
        } else {
            // Subtract-green transform.
            w.write(1, 1); w.write(2, 2)
            for i in 0..<n {
                let p = argb[i]
                let g = (p >> 8) & 0xFF
                let r = (((p >> 16) & 0xFF) &- g) & 0xFF
                let b = ((p & 0xFF) &- g) & 0xFF
                argb[i] = (p & 0xFF00_FF00) | (r << 16) | b
            }
            // Predictor transform.
            let bits = 4
            w.write(1, 1); w.write(0, 2)
            w.write(UInt32(bits - 2), 3)
            let (modes, residuals, bw) = predictorTransform(argb, width: width, height: height, bits: bits)
            writeImage(modes, width: bw, cacheBits: 0, isMain: false, to: &w)
            pixels = residuals
        }
        w.write(0, 1) // no more transforms
        writeImage(pixels, width: xsize, cacheBits: n > 16_000_000 ? 0 : cacheBits, isMain: true, to: &w)

        let bitstream = w.finish()
        var out = Data()
        let pad = bitstream.count & 1
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(le32(UInt32(4 + 8 + bitstream.count + pad)))
        out.append(contentsOf: Array("WEBPVP8L".utf8))
        out.append(le32(UInt32(bitstream.count)))
        out.append(contentsOf: bitstream)
        if pad == 1 { out.append(0) }
        return out
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    /// Sorted palette if the image has at most `limit` distinct colors.
    static func palette(of px: [UInt32], limit: Int) -> [UInt32]? {
        var seen = Set<UInt32>()
        for p in px {
            if seen.insert(p).inserted && seen.count > limit { return nil }
        }
        return seen.sorted()
    }

    // MARK: Pixel math

    @inline(__always) static func subPixels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let ag = 0x00FF_00FF &+ (a & 0xFF00_FF00) &- (b & 0xFF00_FF00)
        let rb = 0xFF00_FF00 &+ (a & 0x00FF_00FF) &- (b & 0x00FF_00FF)
        return (ag & 0xFF00_FF00) | (rb & 0x00FF_00FF)
    }

    @inline(__always) static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xFEFE_FEFE) >> 1) &+ (a & b)
    }

    @inline(__always) static func ch(_ p: UInt32, _ shift: UInt32) -> Int { Int((p >> shift) & 0xFF) }

    @inline(__always) static func clamp(_ v: Int) -> UInt32 { UInt32(v < 0 ? 0 : (v > 255 ? 255 : v)) }

    @inline(__always) static func select(_ l: UInt32, _ t: UInt32, _ tl: UInt32) -> UInt32 {
        var pl = 0, pt = 0
        for s: UInt32 in [24, 16, 8, 0] {
            let est = ch(l, s) + ch(t, s) - ch(tl, s)
            pl += abs(est - ch(l, s))
            pt += abs(est - ch(t, s))
        }
        return pl < pt ? l : t
    }

    @inline(__always) static func clampAddSubtractFull(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for s: UInt32 in [24, 16, 8, 0] { out |= clamp(ch(a, s) + ch(b, s) - ch(c, s)) << s }
        return out
    }

    @inline(__always) static func clampAddSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for s: UInt32 in [24, 16, 8, 0] {
            let x = ch(a, s), y = ch(b, s)
            out |= clamp(x + (x - y) / 2) << s
        }
        return out
    }

    @inline(__always) static func predict(_ px: UnsafeBufferPointer<UInt32>, _ i: Int, _ x: Int, _ y: Int,
                                          _ width: Int, _ mode: Int) -> UInt32 {
        if y == 0 { return x == 0 ? 0xFF00_0000 : px[i - 1] }
        if x == 0 { return px[i - width] }
        let l = px[i - 1], t = px[i - width], tl = px[i - width - 1], tr = px[i - width + 1]
        switch mode {
        case 0: return 0xFF00_0000
        case 1: return l
        case 2: return t
        case 3: return tr
        case 4: return tl
        case 5: return average2(average2(l, tr), t)
        case 6: return average2(l, tl)
        case 7: return average2(l, t)
        case 8: return average2(tl, t)
        case 9: return average2(t, tr)
        case 10: return average2(average2(l, tl), average2(t, tr))
        case 11: return select(l, t, tl)
        case 12: return clampAddSubtractFull(l, t, tl)
        default: return clampAddSubtractHalf(average2(l, t), tl)
        }
    }

    @inline(__always) static func cost(_ residual: UInt32) -> Int {
        abs(Int(Int8(truncatingIfNeeded: residual))) + abs(Int(Int8(truncatingIfNeeded: residual >> 8)))
            + abs(Int(Int8(truncatingIfNeeded: residual >> 16))) + abs(Int(Int8(truncatingIfNeeded: residual >> 24)))
    }

    static func predictorTransform(_ argb: [UInt32], width: Int, height: Int, bits: Int) -> ([UInt32], [UInt32], Int) {
        let block = 1 << bits
        let bw = (width + block - 1) >> bits, bh = (height + block - 1) >> bits
        var modes = [UInt32](repeating: 0, count: bw * bh)
        var residuals = [UInt32](repeating: 0, count: width * height)
        argb.withUnsafeBufferPointer { px in
            residuals.withUnsafeMutableBufferPointer { res in
                for by in 0..<bh {
                    for bx in 0..<bw {
                        let x0 = bx << bits, y0 = by << bits
                        let x1 = min(width, x0 + block), y1 = min(height, y0 + block)
                        var bestMode = 11, bestCost = Int.max
                        for mode in 0..<14 {
                            var c = 0
                            var y = y0
                            while y < y1 && c < bestCost {
                                var x = x0
                                while x < x1 {
                                    let i = y * width + x
                                    c += cost(subPixels(px[i], predict(px, i, x, y, width, mode)))
                                    x += 2
                                }
                                y += 2
                            }
                            if c < bestCost { bestCost = c; bestMode = mode }
                        }
                        modes[by * bw + bx] = 0xFF00_0000 | (UInt32(bestMode) << 8)
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                let i = y * width + x
                                res[i] = subPixels(px[i], predict(px, i, x, y, width, bestMode))
                            }
                        }
                    }
                }
            }
        }
        return (modes, residuals, bw)
    }

    // MARK: Entropy-coded image

    static let distanceTable: [(Int, Int)] = [
        (0, 1), (1, 0), (1, 1), (-1, 1), (0, 2), (2, 0), (1, 2), (-1, 2),
        (2, 1), (-2, 1), (2, 2), (-2, 2), (0, 3), (3, 0), (1, 3), (-1, 3),
        (3, 1), (-3, 1), (2, 3), (-2, 3), (3, 2), (-3, 2), (0, 4), (4, 0),
        (1, 4), (-1, 4), (4, 1), (-4, 1), (3, 3), (-3, 3), (2, 4), (-2, 4),
        (4, 2), (-4, 2), (0, 5), (3, 4), (-3, 4), (4, 3), (-4, 3), (5, 0),
        (1, 5), (-1, 5), (5, 1), (-5, 1), (2, 5), (-2, 5), (5, 2), (-5, 2),
        (4, 4), (-4, 4), (3, 5), (-3, 5), (5, 3), (-5, 3), (0, 6), (6, 0),
        (1, 6), (-1, 6), (6, 1), (-6, 1), (2, 6), (-2, 6), (6, 2), (-6, 2),
        (4, 5), (-4, 5), (5, 4), (-5, 4), (3, 6), (-3, 6), (6, 3), (-6, 3),
        (0, 7), (7, 0), (1, 7), (-1, 7), (5, 5), (-5, 5), (7, 1), (-7, 1),
        (4, 6), (-4, 6), (6, 4), (-6, 4), (2, 7), (-2, 7), (7, 2), (-7, 2),
        (3, 7), (-3, 7), (7, 3), (-7, 3), (5, 6), (-5, 6), (6, 5), (-6, 5),
        (8, 0), (4, 7), (-4, 7), (7, 4), (-7, 4), (8, 1), (8, 2), (6, 6),
        (-6, 6), (8, 3), (5, 7), (-5, 7), (7, 5), (-7, 5), (8, 4), (6, 7),
        (-6, 7), (7, 6), (-7, 6), (8, 5), (7, 7), (-7, 7), (8, 6), (8, 7),
    ]

    /// (prefix symbol, extra bit count, extra bits value) for a length or distance code >= 1.
    @inline(__always) static func prefixEncode(_ value: Int) -> (Int, Int, UInt32) {
        let v = value - 1
        if v < 4 { return (v, 0, 0) }
        let highest = (Int.bitWidth - 1) - v.leadingZeroBitCount
        let second = (v >> (highest - 1)) & 1
        let extraBits = highest - 1
        return (2 * highest + second, extraBits, UInt32(v & ((1 << extraBits) - 1)))
    }

    private static let literalTag: UInt64 = 0
    private static let cacheTag: UInt64 = 1 << 62
    private static let copyTag: UInt64 = 2 << 62

    static func tokenize(_ pixels: [UInt32], width: Int, cacheBits: Int) -> [UInt64] {
        let n = pixels.count
        var tokens = [UInt64]()
        tokens.reserveCapacity(n / 2 + 16)
        var distMap = [Int: Int]()
        for (k, d) in distanceTable.enumerated() {
            let dist = max(1, d.0 + d.1 * width)
            if distMap[dist] == nil { distMap[dist] = k + 1 }
        }
        let useLZ = n <= 16_000_000
        let hashBits = 18
        var head = [Int32](repeating: -1, count: useLZ ? 1 << hashBits : 1)
        var prev = [Int32](repeating: -1, count: useLZ ? n : 1)
        var cache = [UInt32](repeating: 0, count: cacheBits > 0 ? 1 << cacheBits : 1)
        let cacheShift = UInt32(32 - max(cacheBits, 1))
        let maxDist = (1 << 20) - 120
        let maxChain = 24

        pixels.withUnsafeBufferPointer { px in
            head.withUnsafeMutableBufferPointer { head in
                prev.withUnsafeMutableBufferPointer { prev in
                    cache.withUnsafeMutableBufferPointer { cache in
                        @inline(__always) func hashAt(_ i: Int) -> Int {
                            Int(((px[i] &* 0x9E37_79B1) &+ (px[i + 1] &* 0x85EB_CA6B)) >> UInt32(32 - hashBits))
                        }
                        @inline(__always) func insert(_ i: Int) {
                            guard useLZ, i + 1 < n else { return }
                            let h = hashAt(i)
                            prev[i] = head[h]
                            head[h] = Int32(i)
                        }
                        var i = 0
                        while i < n {
                            var bestLen = 0, bestDist = 0
                            let limit = min(4096, n - i)
                            if useLZ && limit >= 3 {
                                @inline(__always) func consider(_ j: Int) {
                                    let d = i - j
                                    guard d > 0, d <= maxDist, px[j + bestLen] == px[i + bestLen] || bestLen == 0 else { return }
                                    var l = 0
                                    while l < limit && px[j + l] == px[i + l] { l += 1 }
                                    if l > bestLen { bestLen = l; bestDist = d }
                                }
                                if i >= 1 { consider(i - 1) }
                                if i >= width && bestLen < limit { consider(i - width) }
                                var j = Int(head[hashAt(i)]), chain = 0
                                while j >= 0 && chain < maxChain && bestLen < limit {
                                    if i - j > maxDist { break }
                                    consider(j)
                                    j = Int(prev[j])
                                    chain += 1
                                }
                            }
                            if bestLen >= 3 {
                                let code = distMap[bestDist] ?? (bestDist + 120)
                                tokens.append(copyTag | (UInt64(bestLen) << 32) | UInt64(code))
                                for k in 0..<bestLen {
                                    if cacheBits > 0 {
                                        let p = px[i + k]
                                        cache[Int((p &* 0x1E35_A7BD) >> cacheShift)] = p
                                    }
                                    insert(i + k)
                                }
                                i += bestLen
                            } else {
                                let p = px[i]
                                if cacheBits > 0 {
                                    let h = Int((p &* 0x1E35_A7BD) >> cacheShift)
                                    if cache[h] == p {
                                        tokens.append(cacheTag | UInt64(h))
                                    } else {
                                        tokens.append(literalTag | UInt64(p))
                                        cache[h] = p
                                    }
                                } else {
                                    tokens.append(literalTag | UInt64(p))
                                }
                                insert(i)
                                i += 1
                            }
                        }
                    }
                }
            }
        }
        return tokens
    }

    static func writeImage(_ pixels: [UInt32], width: Int, cacheBits: Int, isMain: Bool, to w: inout BitWriter) {
        if cacheBits > 0 { w.write(1, 1); w.write(UInt32(cacheBits), 4) } else { w.write(0, 1) }
        if isMain { w.write(0, 1) } // single prefix-code group, no meta codes

        let tokens = tokenize(pixels, width: width, cacheBits: cacheBits)
        let greenSize = 256 + 24 + (cacheBits > 0 ? 1 << cacheBits : 0)
        var hG = [UInt32](repeating: 0, count: greenSize)
        var hR = [UInt32](repeating: 0, count: 256)
        var hB = [UInt32](repeating: 0, count: 256)
        var hA = [UInt32](repeating: 0, count: 256)
        var hD = [UInt32](repeating: 0, count: 40)
        for t in tokens {
            switch t >> 62 {
            case 0:
                let p = UInt32(truncatingIfNeeded: t)
                hG[Int((p >> 8) & 0xFF)] += 1
                hR[Int((p >> 16) & 0xFF)] += 1
                hB[Int(p & 0xFF)] += 1
                hA[Int(p >> 24)] += 1
            case 1:
                hG[280 + Int(t & 0xFFFF)] += 1
            default:
                let len = Int((t >> 32) & 0xFFFF), code = Int(t & 0xFFFF_FFFF)
                hG[256 + prefixEncode(len).0] += 1
                hD[prefixEncode(code).0] += 1
            }
        }
        let cG = Huffman.writeCode(hG, to: &w)
        let cR = Huffman.writeCode(hR, to: &w)
        let cB = Huffman.writeCode(hB, to: &w)
        let cA = Huffman.writeCode(hA, to: &w)
        let cD = Huffman.writeCode(hD, to: &w)

        for t in tokens {
            switch t >> 62 {
            case 0:
                let p = UInt32(truncatingIfNeeded: t)
                cG.put(Int((p >> 8) & 0xFF), &w)
                cR.put(Int((p >> 16) & 0xFF), &w)
                cB.put(Int(p & 0xFF), &w)
                cA.put(Int(p >> 24), &w)
            case 1:
                cG.put(280 + Int(t & 0xFFFF), &w)
            default:
                let len = Int((t >> 32) & 0xFFFF), code = Int(t & 0xFFFF_FFFF)
                let (ls, lb, lv) = prefixEncode(len)
                cG.put(256 + ls, &w)
                w.write(lv, lb)
                let (ds, db, dv) = prefixEncode(code)
                cD.put(ds, &w)
                w.write(dv, db)
            }
        }
    }
}

struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var acc: UInt64 = 0
    private var count = 0

    init() { bytes.reserveCapacity(1 << 16) }

    @inline(__always) mutating func write(_ value: UInt32, _ n: Int) {
        guard n > 0 else { return }
        acc |= (UInt64(value) & ((1 << UInt64(n)) - 1)) << UInt64(count)
        count += n
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: acc))
            acc >>= 8
            count -= 8
        }
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: acc)); acc = 0; count = 0 }
        return bytes
    }
}

struct HuffmanCode {
    var lengths: [UInt8]
    var codes: [UInt16]
    /// Exactly one symbol in use: the decoder reads zero bits for it.
    var single: Bool

    @inline(__always) func put(_ symbol: Int, _ w: inout BitWriter) {
        if single { return }
        w.write(UInt32(codes[symbol]), Int(lengths[symbol]))
    }
}

enum Huffman {
    static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Code lengths limited to `maxLength` (retries with flattened counts until the tree fits).
    static func lengths(for counts: [UInt32], maxLength: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: counts.count)
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.isEmpty { return out }
        if used.count == 1 { out[used[0]] = 1; return out }
        var countMin: UInt64 = 1
        while true {
            let leaves = used.map { (w: max(UInt64(counts[$0]), countMin), s: $0) }
                .sorted { $0.w != $1.w ? $0.w < $1.w : $0.s < $1.s }
            let m = leaves.count
            var weight = leaves.map { $0.w } + [UInt64](repeating: 0, count: m - 1)
            var parent = [Int](repeating: -1, count: 2 * m - 1)
            var li = 0, ii = m, next = m
            func pick() -> Int {
                if li < m && (ii >= next || weight[li] <= weight[ii]) { li += 1; return li - 1 }
                ii += 1
                return ii - 1
            }
            while next < 2 * m - 1 {
                let a = pick(), b = pick()
                weight[next] = weight[a] + weight[b]
                parent[a] = next
                parent[b] = next
                next += 1
            }
            var depth = [Int](repeating: 0, count: 2 * m - 1)
            var maxDepth = 0
            if 2 * m - 3 >= 0 {
                for node in stride(from: 2 * m - 3, through: 0, by: -1) {
                    depth[node] = depth[parent[node]] + 1
                    if node < m { maxDepth = max(maxDepth, depth[node]) }
                }
            }
            if maxDepth <= maxLength {
                for k in 0..<m { out[leaves[k].s] = UInt8(depth[k]) }
                return out
            }
            countMin *= 2
        }
    }

    static func canonicalCodes(_ lengths: [UInt8]) -> [UInt16] {
        var blCount = [Int](repeating: 0, count: 16)
        for l in lengths where l > 0 { blCount[Int(l)] += 1 }
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for bits in 1...15 {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        var codes = [UInt16](repeating: 0, count: lengths.count)
        for (sym, l) in lengths.enumerated() where l > 0 {
            let c = nextCode[Int(l)]
            nextCode[Int(l)] += 1
            var r = 0
            for b in 0..<Int(l) where c & (1 << b) != 0 { r |= 1 << (Int(l) - 1 - b) }
            codes[sym] = UInt16(r)
        }
        return codes
    }

    static func make(_ lengths: [UInt8]) -> HuffmanCode {
        let usedCount = lengths.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        return HuffmanCode(lengths: lengths, codes: canonicalCodes(lengths), single: usedCount <= 1)
    }

    /// Writes a prefix code for `counts` and returns it for emitting symbols.
    static func writeCode(_ counts: [UInt32], to w: inout BitWriter) -> HuffmanCode {
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.count <= 2 && used.allSatisfy({ $0 < 256 }) {
            w.write(1, 1) // simple code
            var lengths = [UInt8](repeating: 0, count: counts.count)
            if used.isEmpty {
                w.write(0, 1); w.write(0, 1); w.write(0, 1)
                return HuffmanCode(lengths: lengths, codes: [UInt16](repeating: 0, count: counts.count), single: true)
            }
            w.write(UInt32(used.count - 1), 1)
            let s0 = used[0]
            if s0 < 2 { w.write(0, 1); w.write(UInt32(s0), 1) } else { w.write(1, 1); w.write(UInt32(s0), 8) }
            if used.count == 2 { w.write(UInt32(used[1]), 8) }
            for s in used { lengths[s] = 1 }
            return make(lengths)
        }

        let lengths = lengths(for: counts, maxLength: 15)
        // Run-length tokens over the code lengths.
        var tokens: [(code: Int, extra: UInt32)] = []
        var i = 0
        while i < lengths.count {
            let v = Int(lengths[i])
            var run = 1
            while i + run < lengths.count && Int(lengths[i + run]) == v { run += 1 }
            i += run
            if v == 0 {
                var r = run
                while r >= 3 {
                    if r >= 11 { let k = min(r, 138); tokens.append((18, UInt32(k - 11))); r -= k }
                    else { let k = min(r, 10); tokens.append((17, UInt32(k - 3))); r -= k }
                }
                for _ in 0..<r { tokens.append((0, 0)) }
            } else {
                tokens.append((v, 0))
                var r = run - 1
                while r >= 3 { let k = min(r, 6); tokens.append((16, UInt32(k - 3))); r -= k }
                for _ in 0..<r { tokens.append((v, 0)) }
            }
        }
        var clCounts = [UInt32](repeating: 0, count: 19)
        for t in tokens { clCounts[t.code] += 1 }
        let clLengths = self.lengths(for: clCounts, maxLength: 7)
        let clCode = make(clLengths)

        w.write(0, 1) // normal code
        var numCodes = 19
        while numCodes > 4 && clLengths[codeLengthOrder[numCodes - 1]] == 0 { numCodes -= 1 }
        w.write(UInt32(numCodes - 4), 4)
        for k in 0..<numCodes { w.write(UInt32(clLengths[codeLengthOrder[k]]), 3) }
        w.write(0, 1) // max_symbol = alphabet size
        for t in tokens {
            clCode.put(t.code, &w)
            switch t.code {
            case 16: w.write(t.extra, 2)
            case 17: w.write(t.extra, 3)
            case 18: w.write(t.extra, 7)
            default: break
            }
        }
        return make(lengths)
    }
}
