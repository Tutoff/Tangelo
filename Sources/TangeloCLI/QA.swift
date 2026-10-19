import AppKit
import CoreGraphics
import Foundation
import TangeloCore

/// Deep QA: runs every action on every sample file and checks the result is *right*
/// (orientation, sizes, codecs, durations, page rotation, text, round-trips…).
struct QA {
    let root: URL
    var pass = 0, fail = 0, skip = 0
    var failures: [String] = []
    var byName: [String: InputItem] = [:]

    static let phrases: [String: String] = [
        "photo.jpg": "Tangelo", "photo.heic": "Tangelo", "oriented.jpg": "Tangelo", "screenshot.png": "Invoice",
        "scan.pdf": "Invoice", "report.pdf": "Quarterly Report", "notes.md": "Project Notes", "letter.docx": "Dear Reader",
        "page.html": "Hello", "readme.txt": "Plain text",
    ]
    static let expectedRefusals = ["already as small", "only one page", "already has selectable text", "Couldn't find a subject",
                                   "No text found", "has no audio track", "isn't password-protected"]
    static let imageUTI: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "webp": "org.webmproject.webp", "avif": "public.avif",
        "tiff": "public.tiff", "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp", "ico": "com.microsoft.ico",
        "icns": "com.apple.icns", "jp2": "public.jpeg-2000", "psd": "com.adobe.photoshop-image", "tga": "com.truevision.tga-image",
    ]
    static let audioCodec: [String: [String]] = [
        "mp3": ["mp3"], "m4a": ["aac"], "alac": ["alac"], "flac": ["flac"], "wav": ["pcm_s16le", "pcm_s24le"],
        "aiff": ["pcm_s16be", "pcm_s24be"], "caf": ["pcm_s16le", "pcm_s24le"], "aac": ["aac"], "m4r": ["aac"],
        "opus": ["opus"], "ogg": ["opus"], "ac3": ["ac3"], "wma": ["wmav2"],
    ]
    static let videoCodec: [String: [String]] = [
        "mp4": ["h264", "hevc"], "mov": ["h264", "hevc"], "m4v": ["h264", "hevc"], "hevc": ["hevc"], "prores": ["prores"],
        "mkv": ["h264", "hevc", "vp9"], "webm": ["vp9"], "avi": ["mpeg4"], "gif": ["gif"],
    ]

    init(root: URL) { self.root = root }

    mutating func record(_ name: String, _ problems: [String], detail: String = "") {
        if problems.isEmpty {
            pass += 1
            print("ok   \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            fail += 1
            let line = "\(name): \(problems.joined(separator: "; "))"
            failures.append(line)
            print("FAIL \(line)")
        }
    }

    // MARK: Runner

    mutating func run() async -> Bool {
        try? FileManager.default.removeItem(at: root)
        let inputs: [URL]
        do { inputs = try await Fixtures.make(in: root.appendingPathComponent("inputs")) } catch {
            print("fixtures failed: \(error)"); return false
        }
        byName = Dictionary(uniqueKeysWithValues: inputs.map { ($0.lastPathComponent, InputItem(url: $0)) })
        let work = root.appendingPathComponent("work")

        for input in inputs {
            let item = InputItem(url: input)
            for action in Catalog.allActions(in: Catalog.pages(for: [item])) where action.tool == nil {
                let dir = work.appendingPathComponent("\(input.lastPathComponent)__\(action.id)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent(input.lastPathComponent)
                try? FileManager.default.copyItem(at: input, to: copy)
                let copied = InputItem(url: copy)
                let ctx = JobContext()
                let name = "\(input.lastPathComponent) → \(action.id)"
                do {
                    let r = try await Runner.run(action.id, items: [copied], ctx: ctx)
                    if r.outputs.isEmpty, r.clipboardText == nil, r.summary == nil, let f = r.failures.first {
                        throw TangeloError.failed(f.message)
                    }
                    let problems = await expect(action.id, input: copied, result: r)
                    record(name, problems, detail: r.outputs.map(\.lastPathComponent).joined(separator: ", "))
                } catch {
                    let msg = error.localizedDescription
                    if Self.expectedRefusals.contains(where: { msg.contains($0) }) { skip += 1; print("skip \(name): \(msg)") }
                    else { record(name, ["error: \(msg)"]) }
                }
            }
        }
        await batches(work)
        await tools(work)
        print("\nQA: \(pass) passed, \(fail) failed, \(skip) expected refusals")
        for f in failures { print("  ✗ \(f)") }
        return fail == 0
    }

    // MARK: Expectations for quick actions

    func expect(_ id: String, input: InputItem, result r: RunResult) async -> [String] {
        var p: [String] = []
        func need(_ ok: Bool, _ msg: @autoclosure () -> String) { if !ok { p.append(msg()) } }
        let parts = id.split(separator: ".", maxSplits: 2).map(String.init)
        let kind = parts[0], verb = parts.count > 1 ? parts[1] : "", arg = parts.count > 2 ? parts[2] : ""
        let outs = r.outputs
        let name = input.url.lastPathComponent
        let phrase = Self.phrases[name]
        let srcSize = ByteFormat.size(of: input.url)
        let srcImage = Probe.image(input.url)
        let srcThumb = Probe.thumb(input.url)
        let o = outs.first

        func similar(_ out: URL, _ limit: Float, transform: (([Float]) -> [Float])? = nil) {
            guard let a = Probe.thumb(out), var b = srcThumb else { p.append("can't compare pixels"); return }
            if let transform { b = transform(b) }
            let d = Probe.diff(a, b)
            need(d < limit, String(format: "pixels differ from expected (%.3f ≥ %.3f)", d, limit))
        }
        func near(_ a: Double, _ b: Double, _ tol: Double, _ what: String) {
            need(abs(a - b) <= tol, String(format: "%@ %.2f, expected %.2f", what, a, b))
        }

        switch (kind, verb) {
        case ("image", "to"):
            guard let o else { return ["no output"] }
            if arg == "mp4" {
                let m = await Probe.media(o)
                need(m?.videoCodec == "h264" && (m?.duration ?? 0) > 0.3, "GIF→MP4 isn't an H.264 video")
                break
            }
            need(o.pathExtension.lowercased() == arg, "extension .\(o.pathExtension)")
            if arg == "pdf" {
                guard let info = Probe.pdf(o) else { return p + ["PDF doesn't open"] }
                need(info.pages == 1, "\(info.pages) pages")
                if let s = srcImage {
                    let a = info.firstPageSize.width / info.firstPageSize.height, b = CGFloat(s.width) / CGFloat(s.height)
                    need(abs(a - b) < 0.02, "page aspect \(a) vs image \(b)")
                }
                break
            }
            guard let oi = Probe.image(o) else { return p + ["image doesn't decode"] }
            need(oi.uti == Self.imageUTI[arg], "type \(oi.uti)")
            if arg == "ico" || arg == "icns" { need(oi.width == oi.height, "icon isn't square"); break }
            need(oi.orientation == 1, "orientation flag \(oi.orientation) left in output")
            if let s = srcImage { need(oi.width == s.width && oi.height == s.height, "size \(oi.width)×\(oi.height), source \(s.width)×\(s.height)") }
            let lossy: Set<String> = ["jpg", "heic", "avif", "webp", "jp2"]
            similar(o, arg == "gif" ? 0.07 : (lossy.contains(arg) ? 0.05 : 0.03))
        case ("image", "ocr"), ("image", "copytext"):
            let text = verb == "copytext" ? (r.clipboardText ?? "") : (o.map(Probe.text) ?? "")
            if let phrase { need(text.localizedCaseInsensitiveContains(phrase), "text lacks “\(phrase)”: \(text.prefix(60))") }
        case ("image", "compress"):
            guard let o, let oi = Probe.image(o) else { return ["no output"] }
            need(ByteFormat.size(of: o) < srcSize, "not smaller")
            if let s = srcImage { need(oi.width <= s.width && oi.height <= s.height, "got bigger") }
            similar(o, arg == "strong" ? 0.07 : 0.05)
        case ("image", "scale"):
            guard let o, let oi = Probe.image(o), let s = srcImage else { return ["no output"] }
            let f = (Double(arg) ?? 50) / 100
            need(abs(Double(oi.width) - (Double(s.width) * f).rounded()) <= 1 && abs(Double(oi.height) - (Double(s.height) * f).rounded()) <= 1,
                 "size \(oi.width)×\(oi.height) for \(arg)% of \(s.width)×\(s.height)")
            similar(o, 0.05)
        case ("image", "rotate"):
            guard let o, let oi = Probe.image(o), let s = srcImage else { return ["no output"] }
            let q = Int(arg) ?? 1
            let ew = q % 2 == 1 ? s.height : s.width, eh = q % 2 == 1 ? s.width : s.height
            need(oi.width == ew && oi.height == eh, "size \(oi.width)×\(oi.height), expected \(ew)×\(eh)")
            need(oi.orientation == 1, "orientation flag \(oi.orientation)")
            similar(o, 0.05) { Probe.rotate($0, size: 32, quarterTurns: q) }
        case ("image", "flip"):
            guard let o, let oi = Probe.image(o), let s = srcImage else { return ["no output"] }
            need(oi.width == s.width && oi.height == s.height, "size changed")
            similar(o, 0.05) { Probe.flip($0, size: 32, horizontal: arg == "h") }
        case ("image", "gray"):
            guard let o, let t = Probe.thumb(o) else { return ["no output"] }
            need(Probe.saturation(t) < 0.02, String(format: "still colorful (%.3f)", Probe.saturation(t)))
        case ("image", "removebg"):
            guard let o, let a = Probe.alphaStats(o) else { return ["no output"] }
            need(a.transparent > 0.05 && a.opaque > 0.01, "cut-out has no transparency (\(a))")
        case ("image", "metadata"):
            guard let o, let oi = Probe.image(o) else { return ["no output"] }
            need(!oi.hasGPS && !oi.hasLens, "metadata still present")
            if let s = srcImage { need(oi.width == s.width && oi.height == s.height, "display orientation changed") }

        case ("pdf", "to"):
            guard let o, let info = Probe.pdf(input.url) else { return ["no output"] }
            if Self.imageUTI[arg] != nil {
                var files = [o]
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: o.path, isDirectory: &isDir), isDir.boolValue {
                    files = ((try? FileManager.default.contentsOfDirectory(at: o, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
                }
                need(files.count == info.pages, "\(files.count) images for \(info.pages) pages")
                if let f = files.first, let oi = Probe.image(f) {
                    let ew = Int((info.firstPageSize.width * 200 / 72).rounded(.up)), eh = Int((info.firstPageSize.height * 200 / 72).rounded(.up))
                    need(abs(oi.width - ew) <= 2 && abs(oi.height - eh) <= 2, "page image \(oi.width)×\(oi.height), expected \(ew)×\(eh)")
                    need(oi.uti == Self.imageUTI[arg], "type \(oi.uti)")
                } else { p.append("page image doesn't decode") }
            } else if let phrase {
                need(Probe.text(o).localizedCaseInsensitiveContains(phrase), "text lacks “\(phrase)”")
            }
        case ("pdf", "compress"):
            guard let o, let info = Probe.pdf(o) else { return ["no output"] }
            need(ByteFormat.size(of: o) < srcSize, "not smaller")
            need(info.pages == Probe.pdf(input.url)?.pages, "page count changed")
        case ("pdf", "rotate"):
            guard let o, let info = Probe.pdf(o) else { return ["no output"] }
            let want = ((Int(arg) ?? 1) * 90) % 360
            need(info.rotations.allSatisfy { $0 == want }, "page rotation \(info.rotations), expected \(want)")
        case ("pdf", "split"):
            guard let o else { return ["no output"] }
            let files = (try? FileManager.default.contentsOfDirectory(at: o, includingPropertiesForKeys: nil)) ?? []
            need(files.count == Probe.pdf(input.url)?.pages, "\(files.count) files")
            need(files.allSatisfy { Probe.pdf($0)?.pages == 1 }, "a split file isn't one page")
        case ("pdf", "ocr"):
            guard let o else { return ["no output"] }
            if let phrase { need(Probe.text(o).localizedCaseInsensitiveContains(phrase), "OCR text lacks “\(phrase)”") }
        case ("pdf", "copytext"), ("doc", "copytext"):
            if let phrase { need((r.clipboardText ?? "").localizedCaseInsensitiveContains(phrase), "copied text lacks “\(phrase)”") }
        case ("doc", "stats"):
            need((r.summary ?? "").contains("words"), "no word count")

        case ("video", "to"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output / unreadable"] }
            need(Self.videoCodec[arg]?.contains(m.videoCodec ?? "") ?? false, "video codec \(m.videoCodec ?? "none")")
            if arg == "gif" {
                need(m.width <= 480 && m.width > 0, "GIF width \(m.width)")
                need(abs(Double(m.width) / Double(max(m.height, 1)) - Double(s.width) / Double(max(s.height, 1))) < 0.03, "GIF aspect changed")
            } else {
                need(m.width == s.width && m.height == s.height, "displayed size \(m.width)×\(m.height), source \(s.width)×\(s.height)")
                near(m.duration, s.duration, 0.35, "duration")
                if s.audioCodec != nil { need(m.audioCodec != nil, "audio track lost") }
            }
        case ("audio", "to"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output / unreadable"] }
            need(Self.audioCodec[arg]?.contains(m.audioCodec ?? "") ?? false, "audio codec \(m.audioCodec ?? "none")")
            need(m.videoCodec == nil || arg == "m4r", "output still has video")
            near(m.duration, arg == "m4r" ? min(s.duration, 40) : s.duration, 0.3, "duration")
        case ("video", "compress"), ("audio", "compress"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output"] }
            need(ByteFormat.size(of: o) < srcSize, "not smaller")
            near(m.duration, s.duration, 0.35, "duration")
        case ("video", "mute"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output"] }
            need(m.audioCodec == nil, "still has audio (\(m.audioCodec ?? ""))")
            need(m.width == s.width && m.height == s.height, "size changed")
            near(m.duration, s.duration, 0.3, "duration")
        case ("video", "rotate"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output"] }
            let q = Int(arg) ?? 1
            let ew = q % 2 == 1 ? s.height : s.width, eh = q % 2 == 1 ? s.width : s.height
            need(m.width == ew && m.height == eh, "displayed size \(m.width)×\(m.height), expected \(ew)×\(eh)")
            if let a = await Probe.frame(input.url), let b = await Probe.frame(o) {
                let d = Probe.diff(Probe.thumb(b), Probe.rotate(Probe.thumb(a), size: 32, quarterTurns: q))
                need(d < 0.06, String(format: "frame isn't rotated correctly (%.3f)", d))
            }
        case ("video", "resize"):
            guard let o, let m = await Probe.media(o) else { return ["no output"] }
            need(min(m.width, m.height) == Int(arg), "short side \(min(m.width, m.height)), expected \(arg)")
        case ("video", "speed"), ("audio", "speed"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output"] }
            near(m.duration, s.duration / (Double(arg) ?? 2), 0.35, "duration")
        case ("video", "snapshot"):
            guard let o, let oi = Probe.image(o), let s = await Probe.media(input.url) else { return ["no output"] }
            need(oi.width == s.width && oi.height == s.height, "frame \(oi.width)×\(oi.height), video \(s.width)×\(s.height)")
        case ("audio", "normalize"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output"] }
            near(m.duration, s.duration, 0.3, "duration")
            if let a = Probe.audio(o), ["wav", "aiff", "caf", "m4a", "flac"].contains(o.pathExtension.lowercased()) {
                need(abs(a.peak - 0.891) < 0.03, String(format: "peak %.3f, expected 0.891", a.peak))
            }
        case ("audio", "mono"):
            guard let o, let m = await Probe.media(o) else { return ["no output"] }
            need(m.channels == 1, "\(m.channels) channels")
        case ("audio", "reverse"):
            guard let o, let s = await Probe.media(input.url), let m = await Probe.media(o) else { return ["no output"] }
            near(m.duration, s.duration, 0.3, "duration")
            if name == "ramp.wav", let a = Probe.audio(input.url), let b = Probe.audio(o) {
                need(a.envelope[0] < a.envelope[9] && b.envelope[0] > b.envelope[9] * 1.5, "not reversed (envelope \(b.envelope.first ?? 0)→\(b.envelope.last ?? 0))")
            }

        case ("doc", "to"):
            guard let o else { return ["no output"] }
            if let phrase { need(Probe.text(o).localizedCaseInsensitiveContains(phrase), "text lacks “\(phrase)”") }
            if arg == "pdf" { need((Probe.pdf(o)?.pages ?? 0) >= 1, "PDF has no pages") }
        case ("data", "to"):
            guard let o else { return ["no output"] }
            let original = (try? DataActions.readTable(input)) ?? []
            if ["csv", "tsv", "json", "xlsx"].contains(arg) {
                let back = (try? DataActions.readTable(InputItem(url: o))) ?? []
                need(back == original, "round-trip differs: \(back.prefix(2)) vs \(original.prefix(2))")
            } else if let header = original.first {
                let text = Probe.text(o)
                need(header.allSatisfy { text.contains($0) }, "header missing")
            }
        case ("data", "json"):
            guard let o, let a = try? JSONSerialization.jsonObject(with: Data(contentsOf: input.url)),
                  let b = try? JSONSerialization.jsonObject(with: Data(contentsOf: o)) else { return ["invalid JSON"] }
            need((a as AnyObject).isEqual(b), "JSON content changed")
        case ("archive", "extract"):
            guard let o else { return ["no output"] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: o.path)) ?? []
            need(names.contains("readme.txt") && names.contains("people.csv"), "extracted \(names)")
        case ("any", "zip"), ("any", "targz"):
            guard let o else { return ["no output"] }
            let listing = await Probe.listing(o)
            need(listing.contains(input.url.lastPathComponent), "archive doesn't contain \(input.url.lastPathComponent)")
        default:
            p.append("no expectation written for \(id)")
        }
        return p
    }

    // MARK: Multi-file actions

    mutating func batches(_ work: URL) async {
        func copies(_ names: [String], _ id: String) -> [InputItem] {
            let dir = work.appendingPathComponent("batch__\(id)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return names.compactMap { byName[$0] }.map { i in
                let c = dir.appendingPathComponent(i.url.lastPathComponent)
                try? FileManager.default.copyItem(at: i.url, to: c)
                return InputItem(url: c)
            }
        }
        let cases: [(String, [String])] = [
            ("image.merge.pdf", ["photo.jpg", "screenshot.png"]), ("image.merge.gif", ["photo.jpg", "screenshot.png"]),
            ("image.stitch.v", ["photo.jpg", "screenshot.png"]), ("image.stitch.h", ["photo.jpg", "screenshot.png"]),
            ("pdf.merge", ["report.pdf", "scan.pdf"]), ("mixed.combine", ["report.pdf", "photo.jpg"]),
            ("doc.merge", ["notes.md", "readme.txt"]), ("any.zip", ["photo.jpg", "notes.md"]), ("any.targz", ["photo.jpg", "notes.md"]),
            ("audio.merge", ["tone.wav", "song.mp3"]), ("video.merge", ["clip.mp4", "portrait.mov"]),
            ("image.to.jpg", ["photo.heic", "screenshot.png"]), ("image.compress.balanced", ["photo.jpg", "screenshot.png"]),
            ("image.rotate.1", ["photo.jpg", "oriented.jpg"]),
        ]
        for (id, names) in cases {
            let items = copies(names, id)
            guard items.count == names.count else { continue }
            let ctx = JobContext()
            var p: [String] = []
            do {
                let r = try await Runner.run(id, items: items, ctx: ctx)
                let o = r.outputs.first
                switch id {
                case "image.merge.pdf": p += Probe.pdf(o!)?.pages == 2 ? [] : ["expected 2 pages"]
                case "image.merge.gif": p += Probe.image(o!)?.frames == 2 ? [] : ["expected 2 frames"]
                case "image.stitch.v", "image.stitch.h":
                    let a = Probe.image(items[0].url)!, b = Probe.image(items[1].url)!, out = Probe.image(o!)!
                    if id.hasSuffix(".v") {
                        let w = min(a.width, b.width)
                        let h = Int((Double(a.height) * Double(w) / Double(a.width)).rounded(.down)) + Int((Double(b.height) * Double(w) / Double(b.width)).rounded(.down))
                        if out.width != w || abs(out.height - h) > 2 { p.append("stitched \(out.width)×\(out.height), expected \(w)×\(h)") }
                    } else {
                        let h = min(a.height, b.height)
                        let w = Int((Double(a.width) * Double(h) / Double(a.height)).rounded(.down)) + Int((Double(b.width) * Double(h) / Double(b.height)).rounded(.down))
                        if out.height != h || abs(out.width - w) > 2 { p.append("stitched \(out.width)×\(out.height), expected \(w)×\(h)") }
                    }
                case "pdf.merge": p += Probe.pdf(o!)?.pages == 4 ? [] : ["expected 4 pages, got \(Probe.pdf(o!)?.pages ?? 0)"]
                case "mixed.combine": p += Probe.pdf(o!)?.pages == 4 ? [] : ["expected 4 pages"]
                case "doc.merge":
                    let t = Probe.text(o!)
                    if !(t.contains("Project Notes") && t.contains("Plain text")) { p.append("merged PDF lacks one document") }
                case "any.zip", "any.targz":
                    let l = await Probe.listing(o!)
                    if !(l.contains("photo.jpg") && l.contains("notes.md")) { p.append("archive missing files") }
                case "audio.merge":
                    let d = await Probe.media(o!)?.duration ?? 0
                    if abs(d - 7) > 0.4 { p.append(String(format: "duration %.2f, expected 7", d)) }
                case "video.merge":
                    let m = await Probe.media(o!)
                    if abs((m?.duration ?? 0) - 5) > 0.4 { p.append("duration \(m?.duration ?? 0), expected 5") }
                    if m?.width != 640 || m?.height != 360 { p.append("size \(m?.width ?? 0)×\(m?.height ?? 0)") }
                case "image.rotate.1":
                    if r.outputs.count != 2 { p.append("\(r.outputs.count) outputs") }
                    for (item, out) in zip(items, r.outputs) {
                        let s = Probe.image(item.url)!, oi = Probe.image(out)!
                        if oi.width != s.height || oi.height != s.width { p.append("\(item.url.lastPathComponent) not rotated (\(oi.width)×\(oi.height))") }
                        if let a = Probe.thumb(item.url), let b = Probe.thumb(out), Probe.diff(b, Probe.rotate(a, size: 32, quarterTurns: 1)) > 0.05 {
                            p.append("\(item.url.lastPathComponent) pixels not rotated right")
                        }
                    }
                default:
                    if r.outputs.count != items.count { p.append("\(r.outputs.count) outputs for \(items.count) files") }
                }
                record("batch \(id)", p, detail: r.outputs.map(\.lastPathComponent).joined(separator: ", "))
            } catch {
                record("batch \(id)", ["error: \(error.localizedDescription)"])
            }
        }
    }

    // MARK: Tool-window back-ends

    mutating func tools(_ work: URL) async {
        func tool(_ name: String, _ input: String, _ body: (InputItem, JobContext) async throws -> [String]) async {
            guard let src = byName[input] else { return }
            let dir = work.appendingPathComponent("tool__\(name)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(src.url.lastPathComponent)
            try? FileManager.default.copyItem(at: src.url, to: copy)
            let ctx = JobContext()
            do {
                let problems = try await body(InputItem(url: copy), ctx)
                record("tool \(name)", ctx.outputs.isEmpty ? ["no output"] + problems : problems,
                       detail: ctx.outputs.map(\.lastPathComponent).joined(separator: ", "))
            } catch { record("tool \(name)", ["error: \(error.localizedDescription)"]) }
        }
        await tool("crop", "photo.jpg") { item, ctx in
            let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
            try await ImageActions.crop(item, rect: rect, ctx: ctx)
            let o = ctx.outputs[0], oi = Probe.image(o)!
            var p: [String] = oi.width == 800 && oi.height == 600 ? [] : ["size \(oi.width)×\(oi.height)"]
            let expected = Probe.thumb(try ImageKit.load(item.url).image.cropping(to: rect)!)
            if Probe.diff(Probe.thumb(o)!, expected) > 0.05 { p.append("crop shows the wrong area") }
            return p
        }
        await tool("crop-oriented", "oriented.jpg") { item, ctx in
            let rect = CGRect(x: 0, y: 0, width: 500, height: 900)
            try await ImageActions.crop(item, rect: rect, ctx: ctx)
            let o = ctx.outputs[0], oi = Probe.image(o)!
            var p: [String] = oi.width == 500 && oi.height == 900 ? [] : ["size \(oi.width)×\(oi.height)"]
            let expected = Probe.thumb(try ImageKit.load(item.url).image.cropping(to: rect)!)
            if Probe.diff(Probe.thumb(o)!, expected) > 0.05 { p.append("crop of a rotated photo shows the wrong area") }
            return p
        }
        await tool("resize", "photo.jpg") { item, ctx in
            try await ImageActions.resize(item, width: 640, height: 400, ctx: ctx)
            let oi = Probe.image(ctx.outputs[0])!
            return oi.width == 640 && oi.height == 400 ? [] : ["size \(oi.width)×\(oi.height)"]
        }
        await tool("add-background", "screenshot.png") { item, ctx in
            var style = BackdropStyle(); style.aspect = .square; style.padding = 80; style.cornerRadius = 24; style.shadow = 30
            let out = ImageRender.addBackground(try ImageKit.load(item.url).image, style: style)!
            try await ImageActions.saveEdited(out, like: item, suffix: "With Background", forcePNG: true, ctx: ctx)
            let oi = Probe.image(ctx.outputs[0])!
            return oi.width == oi.height && oi.width == 900 + 160 ? [] : ["canvas \(oi.width)×\(oi.height), expected 1060×1060"]
        }
        await tool("annotate", "photo.jpg") { item, ctx in
            let red = RGBA(hex: 0xF0412B)
            let marks: [ImageRender.Annotation] = [
                .init(kind: .rect(CGRect(x: 100, y: 100, width: 600, height: 400)), color: red, width: 12),
                .init(kind: .text("Look here", CGPoint(x: 120, y: 600)), color: red, width: 10),
            ]
            let src = try ImageKit.load(item.url).image
            let out = ImageRender.renderAnnotations(src, marks)!
            try await ImageActions.saveEdited(out, like: item, suffix: "Annotated", ctx: ctx)
            // The box's top edge (y≈100 from the top) must be red in the saved file.
            let saved = try ImageKit.load(ctx.outputs[0]).image
            let px = ImageKit.rgbaPixels(saved)!
            let i = (100 * saved.width + 400) * 4
            return px[i] > 200 && px[i + 1] < 120 ? [] : ["annotation not where it was drawn (\(px[i]),\(px[i + 1]),\(px[i + 2]))"]
        }
        await tool("redact", "screenshot.png") { item, ctx in
            let img = try ImageKit.load(item.url).image
            let lines = try VisionKit.recognizeLines(in: img)
            let boxes = lines.map { ImageRender.Redaction(rect: $0.rect, style: .pixelate) }
            let out = ImageRender.renderRedactions(img, boxes)!
            try await ImageActions.saveEdited(out, like: item, suffix: "Redacted", ctx: ctx)
            let again = (try? VisionKit.recognizeText(in: try ImageKit.load(ctx.outputs[0]).image)) ?? ""
            return again.localizedCaseInsensitiveContains("Invoice") ? ["text still readable after redaction"] : []
        }
        await tool("edit", "photo.jpg") { item, ctx in
            var a = ImageRender.Adjustments(); a.saturation = 0; a.quarterTurns = 1
            let out = ImageRender.render(try ImageKit.load(item.url).image, adjustments: a)!
            try await ImageActions.saveEdited(out, like: item, suffix: "Edited", ctx: ctx)
            let oi = Probe.image(ctx.outputs[0])!
            var p: [String] = oi.width == 1000 && oi.height == 1600 ? [] : ["size \(oi.width)×\(oi.height)"]
            if let t = Probe.thumb(ctx.outputs[0]), Probe.saturation(t) > 0.03 { p.append("saturation slider had no effect") }
            if let src = Probe.thumb(item.url), let t = Probe.thumb(ctx.outputs[0]) {
                // Compare luminance only (saturation was removed).
                func luma(_ x: [Float]) -> [Float] { stride(from: 0, to: x.count, by: 3).flatMap { i -> [Float] in let l = 0.3 * x[i] + 0.59 * x[i + 1] + 0.11 * x[i + 2]; return [l, l, l] } }
                if Probe.diff(luma(t), luma(Probe.rotate(src, size: 32, quarterTurns: 1))) > 0.08 { p.append("edit rotation went the wrong way") }
            }
            return p
        }
        await tool("strip-metadata", "photo.jpg") { item, ctx in
            try await ImageMeta.strip(item, ctx: ctx)
            let oi = Probe.image(ctx.outputs[0])!
            return !oi.hasGPS && !oi.hasLens ? [] : ["metadata still present"]
        }
        await tool("strip-location-heic", "photo.heic") { item, ctx in
            try await ImageMeta.strip(item, onlyLocation: true, ctx: ctx)
            return Probe.image(ctx.outputs[0])!.hasGPS ? ["GPS still present"] : []
        }
        await tool("strip-oriented", "oriented.jpg") { item, ctx in
            try await ImageMeta.strip(item, ctx: ctx)
            let oi = Probe.image(ctx.outputs[0])!
            return oi.width == 1000 && oi.height == 1600 ? [] : ["photo no longer upright (\(oi.width)×\(oi.height))"]
        }
        await tool("pdf-protect-unlock", "report.pdf") { item, ctx in
            try await PDFActions.protect(item, password: "tangelo", ctx: ctx)
            guard let locked = ctx.outputs.first, Probe.pdf(locked)?.encrypted == true else { return ["not encrypted"] }
            try await PDFActions.unlock(InputItem(url: locked), password: "tangelo", ctx: ctx)
            let info = Probe.pdf(ctx.outputs.last!)!
            return !info.encrypted && info.text.contains("Quarterly") && info.pages == 3 ? [] : ["unlocked copy wrong"]
        }
        await tool("pdf-unlock-wrong-password", "report.pdf") { item, ctx in
            try await PDFActions.protect(item, password: "right", ctx: ctx)
            do { try await PDFActions.unlock(InputItem(url: ctx.outputs[0]), password: "wrong", ctx: ctx); return ["accepted a wrong password"] }
            catch { return error.localizedDescription.contains("Wrong password") ? [] : ["unexpected error: \(error.localizedDescription)"] }
        }
        for (name, file, start, end) in [("trim-wav", "tone.wav", 0.5, 2.0), ("trim-mp3", "song.mp3", 1.0, 3.0),
                                         ("trim-mp4", "clip.mp4", 0.5, 2.5), ("trim-webm", "web.webm", 0.2, 1.5),
                                         ("trim-rotated-mov", "rotated.mov", 0.5, 1.5)] {
            await tool(name, file) { item, ctx in
                try await AudioActions.trim(item, start: start, end: end, ctx: ctx)
                guard let m = await Probe.media(ctx.outputs[0]), let s = await Probe.media(item.url) else { return ["unreadable"] }
                var p: [String] = []
                // Stream-copy trims of video snap to the previous keyframe, so allow the start to move earlier.
                let tolerance = file.hasSuffix(".webm") ? 0.25 + start : 0.25
                if abs(m.duration - (end - start)) > tolerance { p.append(String(format: "duration %.2f, expected %.2f", m.duration, end - start)) }
                if m.width != s.width || m.height != s.height { p.append("displayed size changed \(m.width)×\(m.height) vs \(s.width)×\(s.height)") }
                return p
            }
        }
    }
}
