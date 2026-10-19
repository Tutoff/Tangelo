import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import TangeloCore

/// Generates sample files of every kind for end-to-end testing.
enum Fixtures {
    static func make(in dir: URL) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        let settings = EngineSettings()

        // Photo with EXIF + GPS
        let photo = drawImage(width: 1600, height: 1000) { ctx, w, h in
            let colors = [CGColor(red: 0.98, green: 0.55, blue: 0.2, alpha: 1), CGColor(red: 0.5, green: 0.2, blue: 0.6, alpha: 1)] as CFArray
            let g = CGGradient(colorsSpace: ImageKit.sRGB, colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.6, y: h * 0.55, width: 300, height: 300))
            drawText("Tangelo test photo", in: ctx, at: CGPoint(x: 80, y: 120), size: 72, color: .white)
        }
        let jpg = dir.appendingPathComponent("photo.jpg")
        let exif: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifLensModel as String: "Test Lens 35mm", kCGImagePropertyExifISOSpeedRatings as String: [200]],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple", kCGImagePropertyTIFFModel as String: "iPhone Test"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 45.5, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                      kCGImagePropertyGPSLongitude as String: 73.56, kCGImagePropertyGPSLongitudeRef as String: "W"],
        ]
        try ImageKit.write(photo, to: jpg, format: .jpg, quality: 0.92, properties: exif, settings: settings)
        out.append(jpg)
        let heic = dir.appendingPathComponent("photo.heic")
        try ImageKit.write(photo, to: heic, format: .heic, quality: 0.8, properties: exif, settings: settings)
        out.append(heic)

        // Screenshot-like PNG with transparency and text
        let shot = drawImage(width: 900, height: 600) { ctx, w, h in
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 20, width: w - 40, height: h - 40), cornerWidth: 24, cornerHeight: 24, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(CGColor(red: 0.94, green: 0.35, blue: 0.16, alpha: 1))
            ctx.fill(CGRect(x: 60, y: h - 140, width: 220, height: 60))
            drawText("Invoice #10423", in: ctx, at: CGPoint(x: 60, y: h - 230), size: 44, color: .black)
            drawText("Total due: $1,250.00", in: ctx, at: CGPoint(x: 60, y: h - 300), size: 36, color: .darkGray)
            drawText("Call 555-0182 for questions", in: ctx, at: CGPoint(x: 60, y: h - 360), size: 30, color: .darkGray)
        }
        let png = dir.appendingPathComponent("screenshot.png")
        try ImageKit.write(shot, to: png, format: .png, quality: 1, settings: settings)
        out.append(png)

        // SVG
        let svg = dir.appendingPathComponent("logo.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">
        <circle cx="60" cy="60" r="56" fill="#F26B2A"/><path d="M60 10 C70 30 90 30 100 20" stroke="#3a7d2c" stroke-width="8" fill="none"/>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        out.append(svg)

        // Animated GIF
        let frames = (0..<6).map { i in
            drawImage(width: 200, height: 120) { ctx, w, h in
                ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: CGFloat(i) * 28, y: 30, width: 50, height: 50))
            }
        }
        let gif = dir.appendingPathComponent("bounce.gif")
        try ImageKit.writeGIF(frames: frames, delay: 0.1, to: gif)
        out.append(gif)

        // Text PDF (3 pages) and a scanned (image-only) PDF
        let pdf = dir.appendingPathComponent("report.pdf")
        try makeTextPDF(at: pdf, pages: 3)
        out.append(pdf)
        let scanned = dir.appendingPathComponent("scan.pdf")
        try ImageKit.writePDF(pages: [shot], dpi: 144, to: scanned)
        out.append(scanned)

        // Audio: 3 s stereo sine
        let wav = dir.appendingPathComponent("tone.wav")
        try makeTone(at: wav, seconds: 3)
        out.append(wav)

        // Video via ffmpeg test source (or skip without ffmpeg)
        if let ff = settings.ffmpegPath {
            let mp4 = dir.appendingPathComponent("clip.mp4")
            _ = try await ProcessRunner.checked(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=3:size=640x360:rate=30",
                                                     "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                                                     "-c:a", "aac", "-shortest", mp4.path])
            out.append(mp4)
            let mov = dir.appendingPathComponent("portrait.mov")
            _ = try await ProcessRunner.checked(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=duration=2:size=360x640:rate=30",
                                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", mov.path])
            out.append(mov)
            let mp3 = dir.appendingPathComponent("song.mp3")
            _ = try await ProcessRunner.checked(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=330:duration=4",
                                                     "-c:a", "libmp3lame", "-q:a", "4", mp3.path])
            out.append(mp3)
            let webm = dir.appendingPathComponent("web.webm")
            _ = try await ProcessRunner.checked(ff, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
                                                     "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", webm.path])
            out.append(webm)
        }

        // Documents
        let md = dir.appendingPathComponent("notes.md")
        try """
        # Project Notes

        Some **bold**, some *italic*, a `code span` and a [link](https://example.com).

        ## Checklist
        - [x] Design the ring
        - [ ] Ship it
          - nested item

        1. First
        2. Second

        > A quote worth keeping.

        | Format | Native |
        |--------|:------:|
        | HEIC   | yes    |
        | WebP   | yes    |

        ```swift
        print("hello")
        ```
        """.write(to: md, atomically: true, encoding: .utf8)
        out.append(md)
        let txt = dir.appendingPathComponent("readme.txt")
        try "Plain text file.\n\nSecond paragraph with some words to count.".write(to: txt, atomically: true, encoding: .utf8)
        out.append(txt)
        let html = dir.appendingPathComponent("page.html")
        try "<html><body><h1>Hello</h1><p>This is <b>HTML</b> with a <a href='https://apple.com'>link</a>.</p><ul><li>One</li><li>Two</li></ul></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        out.append(html)
        let docx = dir.appendingPathComponent("letter.docx")
        let attr = NSMutableAttributedString(string: "Dear Reader,\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        attr.append(NSAttributedString(string: "This letter was written by the Tangelo test suite. It has a second sentence.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx)
        out.append(docx)

        // Data
        let csv = dir.appendingPathComponent("people.csv")
        try "name,age,city,note\nAda,36,London,\"likes, commas\"\nGrace,45,New York,\"says \"\"hi\"\"\"\nLinus,28,Helsinki,\n".write(to: csv, atomically: true, encoding: .utf8)
        out.append(csv)
        let json = dir.appendingPathComponent("items.json")
        try #"[{"id":1,"name":"Widget","price":9.99,"tags":["a","b"]},{"id":2,"name":"Gadget","price":19.5,"active":true}]"#
            .write(to: json, atomically: true, encoding: .utf8)
        out.append(json)

        // iPhone-style photo: landscape pixels + EXIF orientation 6 (displays as portrait).
        let oriented = dir.appendingPathComponent("oriented.jpg")
        var orientedProps = exif
        orientedProps[kCGImagePropertyOrientation as String] = 6
        orientedProps[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFOrientation as String: 6]
        if let dest = CGImageDestinationCreateWithURL(oriented as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, photo, orientedProps as CFDictionary)
            CGImageDestinationFinalize(dest)
            out.append(oriented)
        }

        // Audio that gets louder over time (makes reversal measurable).
        let ramp = dir.appendingPathComponent("ramp.wav")
        try makeTone(at: ramp, seconds: 2, ramp: true)
        out.append(ramp)

        // Video carrying a 90° display rotation (like a portrait iPhone clip).
        if let ff = settings.ffmpegPath {
            let rotated = dir.appendingPathComponent("rotated.mov")
            let src = dir.appendingPathComponent("clip.mp4")
            if (try? await ProcessRunner.checked(ff, ["-y", "-loglevel", "error", "-display_rotation", "90", "-i", src.path, "-c", "copy", rotated.path])) != nil {
                out.append(rotated)
            }
        }

        // Archive
        let zip = dir.appendingPathComponent("bundle.zip")
        _ = try await ProcessRunner.checked("/usr/bin/zip", ["-q", "-j", zip.path, txt.path, csv.path])
        out.append(zip)
        return out
    }

    static func drawImage(width: Int, height: Int, _ body: (CGContext, CGFloat, CGFloat) -> Void) -> CGImage {
        let ctx = ImageKit.makeContext(width: width, height: height)!
        body(ctx, CGFloat(width), CGFloat(height))
        return ctx.makeImage()!
    }

    static func drawText(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat, color: NSColor) {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    static func makeTextPDF(at url: URL, pages: Int) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return }
        for p in 1...pages {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            drawText("Quarterly Report — Page \(p)", in: ctx, at: CGPoint(x: 72, y: 700), size: 24, color: .black)
            for i in 0..<20 {
                let a = NSAttributedString(string: "Line \(i + 1): revenue grew steadily across all regions this quarter.",
                                           attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
                ctx.textPosition = CGPoint(x: 72, y: 660 - CGFloat(i) * 22)
                CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func makeTone(at url: URL, seconds: Double, ramp: Bool = false) throws {
        let sr = 44_100.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<2 {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(frames) {
                let gain = ramp ? 0.05 + 0.6 * Double(i) / Double(frames) : 0.4
                p[i] = Float(sin(2 * .pi * (c == 0 ? 440 : 660) * Double(i) / sr) * gain)
            }
        }
        try file.write(from: buf)
    }
}
