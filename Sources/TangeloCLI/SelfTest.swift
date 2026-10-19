import CoreGraphics
import Foundation
import ImageIO
import TangeloCore

func makeTestImage(width: Int, height: Int, kind: Int) -> CGImage {
    var px = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt32 = 12345
    func rnd() -> UInt32 { seed = seed &* 1_103_515_245 &+ 12345; return (seed >> 16) & 0x7FFF }
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            switch kind {
            case 0: // photo-like: smooth gradients + noise
                px[i] = UInt8(clamping: (x * 255 / max(width - 1, 1)) + Int(rnd() % 7) - 3)
                px[i + 1] = UInt8(clamping: (y * 255 / max(height - 1, 1)) + Int(rnd() % 5) - 2)
                px[i + 2] = UInt8(clamping: ((x + y) * 128 / max(width + height, 1)) + Int(rnd() % 9))
                px[i + 3] = 255
            case 1: // graphic: few flat colors
                let c = ((x / 17) + (y / 11)) % 5
                let pal: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (240, 90, 40), (30, 30, 30), (60, 140, 230), (250, 200, 60)]
                px[i] = pal[c].0; px[i + 1] = pal[c].1; px[i + 2] = pal[c].2; px[i + 3] = 255
            default: // alpha gradient, many colors
                px[i] = UInt8((x * 7) & 255); px[i + 1] = UInt8((y * 3) & 255); px[i + 2] = UInt8((x ^ y) & 255)
                px[i + 3] = UInt8(clamping: (x + y) % 256)
            }
        }
    }
    return ImageKit.image(fromRGBA: px, width: width, height: height)!
}

/// Encodes test images with the built-in VP8L encoder and checks Apple's decoder returns identical pixels.
func selftestWebP() -> Bool {
    var settings = EngineSettings()
    settings.cwebpPath = nil
    var ok = true
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tangelo-selftest", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let cases: [(Int, Int, Int)] = [(1, 1, 0), (3, 2, 1), (64, 48, 0), (257, 129, 0), (300, 200, 1), (128, 96, 2), (640, 480, 0), (1000, 37, 1), (2000, 1500, 0)]
    for (w, h, kind) in cases {
        let img = makeTestImage(width: w, height: h, kind: kind)
        let url = dir.appendingPathComponent("t-\(w)x\(h)-\(kind).webp")
        do {
            let t0 = Date()
            try WebP.write(img, to: url, quality: 0.8, lossless: true, settings: settings)
            let dt = Date().timeIntervalSince(t0)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let dec = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                print("FAIL decode \(w)x\(h) kind \(kind)"); ok = false; continue
            }
            let a = ImageKit.rgbaPixels(img)!, b = ImageKit.rgbaPixels(dec)!
            let size = ByteFormat.size(of: url)
            if dec.width != w || dec.height != h || a != b {
                var diffs = 0
                for i in 0..<min(a.count, b.count) where a[i] != b[i] { diffs += 1 }
                print("FAIL pixels \(w)x\(h) kind \(kind): \(diffs) bytes differ")
                ok = false
            } else {
                print("ok   \(w)x\(h) kind \(kind): \(ByteFormat.string(size)), \(String(format: "%.3f", dt))s")
            }
        } catch {
            print("FAIL encode \(w)x\(h): \(error)"); ok = false
        }
    }
    return ok
}
