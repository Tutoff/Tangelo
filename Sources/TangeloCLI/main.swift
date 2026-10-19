import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import TangeloCore

// tangelo-cli: run Tangelo's conversions from the terminal, and test them.

_ = NSApplication.shared
setvbuf(stdout, nil, _IONBF, 0)

func usage() -> Never {
    print("""
    usage:
      tangelo-cli menu <files...>              Show the ring pages and actions for these files
      tangelo-cli run <action-id> <files...>   Run an action (e.g. image.to.webp, pdf.compress.balanced)
      tangelo-cli test-all [dir]               Generate sample files and test every quick action
      tangelo-cli selftest-webp                Round-trip test of the built-in WebP encoder
      tangelo-cli qa [dir]                     Deep QA: checks every result is correct, not just present
      tangelo-cli job                          Run one job described by JSON on stdin, streaming JSON lines (used by the app)
    """)
    exit(2)
}

func describe(_ pages: [MenuPage]) {
    for p in pages {
        print("[\(p.title)]")
        for e in p.entries {
            switch e {
            case .action(let a): print("  \(a.title.padding(toLength: 12, withPad: " ", startingAt: 0)) \(a.id)\(a.tool != nil ? "  (window)" : "")")
            case .group(let t, _, let children, let primary):
                print("  \(t.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(primary.id)")
                for c in children { print("      \(c.title.padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.id)") }
            }
        }
    }
}

func runAction(_ id: String, _ items: [InputItem], quiet: Bool = false) async -> (RunResult?, Error?) {
    let ctx = JobContext()
    if !quiet {
        ctx.progressHandler = { f, d in
            if let f { FileHandle.standardError.write("\r\(Int(f * 100))% \(d ?? "")    ".data(using: .utf8)!) }
        }
    }
    do {
        let r = try await Runner.run(id, items: items, ctx: ctx)
        if !quiet { FileHandle.standardError.write("\r".data(using: .utf8)!) }
        return (r, nil)
    } catch {
        return (nil, error)
    }
}

/// Opens an output with the right framework to prove it's a valid file.
func verify(_ url: URL) async -> String? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return "missing" }
    if isDir.boolValue {
        let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        return n > 0 ? nil : "empty folder"
    }
    let size = ByteFormat.size(of: url)
    guard size > 0 else { return "empty file" }
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "jpg", "jpeg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "ico", "icns", "jp2", "psd", "tga":
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width > 0 else { return "image doesn't decode" }
    case "pdf":
        guard let d = PDFDocument(url: url), d.pageCount > 0 else { return "PDF doesn't open" }
    case "mp4", "mov", "m4v", "m4a", "wav", "aiff", "caf", "aac", "m4r", "flac", "mp3":
        let d = await Media.duration(of: url, ctx: JobContext()) ?? 0
        if d <= 0 { return "media has no duration" }
    case "webm", "mkv", "avi", "opus", "ogg", "ac3", "wma":
        let d = await FFmpeg.probeDuration(url, ctx: JobContext()) ?? 0
        if d <= 0 { return "media has no duration (ffprobe)" }
    case "docx", "doc", "rtf", "odt", "html", "webarchive", "rtfd":
        guard let s = try? NSAttributedString(url: url, options: [:], documentAttributes: nil), !s.string.isEmpty else { return "document doesn't open" }
    case "txt", "md", "csv", "tsv", "json":
        guard let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty else { return "text is empty" }
        if ext == "json", (try? JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.fragmentsAllowed])) == nil { return "invalid JSON" }
    case "xlsx", "zip":
        let r = try? await ProcessRunner.run("/usr/bin/unzip", ["-tq", url.path])
        if r?.status != 0 { return "zip test failed" }
    default: break
    }
    return nil
}

func testAll(dir: URL) async -> Bool {
    try? FileManager.default.removeItem(at: dir)
    let inputs: [URL]
    do { inputs = try await Fixtures.make(in: dir.appendingPathComponent("inputs")) } catch {
        print("fixture generation failed: \(error)"); return false
    }
    let outDir = dir.appendingPathComponent("outputs")
    var pass = 0, fail = 0
    var failures: [String] = []
    for input in inputs {
        let item = InputItem(url: input)
        let pages = Catalog.pages(for: [item])
        for action in Catalog.allActions(in: pages) where action.tool == nil {
            // Each action writes into its own folder so names never collide.
            let work = outDir.appendingPathComponent("\(input.lastPathComponent)-\(action.id)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent(input.lastPathComponent)
            try? FileManager.default.copyItem(at: input, to: copy)
            let t0 = Date()
            let (result, error) = await runAction(action.id, [InputItem(url: copy)], quiet: true)
            let dt = String(format: "%.2fs", Date().timeIntervalSince(t0))
            if let error {
                let msg = error.localizedDescription
                // Expected refusals are not failures.
                let expected = ["already as small", "only one page", "already has selectable text", "Couldn't find a subject",
                                "No text found", "has no audio track"].contains { msg.contains($0) }
                if expected { print("skip \(input.lastPathComponent) → \(action.id): \(msg)"); continue }
                fail += 1; failures.append("\(input.lastPathComponent) → \(action.id): \(msg)")
                print("FAIL \(input.lastPathComponent) → \(action.id) (\(dt)): \(msg)")
                continue
            }
            guard let result else { continue }
            if result.outputs.isEmpty {
                let info = result.summary ?? result.clipboardText.map { "clipboard: \($0.prefix(40).replacingOccurrences(of: "\n", with: " "))…" } ?? "no output"
                if result.summary == nil && result.clipboardText == nil { fail += 1; failures.append("\(input.lastPathComponent) → \(action.id): no output") }
                else { pass += 1 }
                print("ok   \(input.lastPathComponent) → \(action.id) (\(dt)): \(info)")
                continue
            }
            var problems: [String] = []
            for o in result.outputs { if let p = await verify(o) { problems.append("\(o.lastPathComponent): \(p)") } }
            if problems.isEmpty {
                pass += 1
                let names = result.outputs.map { "\($0.lastPathComponent) (\(ByteFormat.string(ByteFormat.size(of: $0))))" }.joined(separator: ", ")
                print("ok   \(input.lastPathComponent) → \(action.id) (\(dt)): \(names)\(result.summary.map { " — \($0)" } ?? "")")
            } else {
                fail += 1; failures.append("\(input.lastPathComponent) → \(action.id): \(problems.joined(separator: "; "))")
                print("FAIL \(input.lastPathComponent) → \(action.id): \(problems.joined(separator: "; "))")
            }
        }
    }
    // Multi-file actions
    let byName = Dictionary(uniqueKeysWithValues: inputs.map { ($0.lastPathComponent, InputItem(url: $0)) })
    let batches: [(String, [String])] = [
        ("image.merge.pdf", ["photo.jpg", "screenshot.png"]), ("image.merge.gif", ["photo.jpg", "screenshot.png"]),
        ("image.stitch.v", ["photo.jpg", "screenshot.png"]), ("image.stitch.h", ["photo.jpg", "screenshot.png"]),
        ("pdf.merge", ["report.pdf", "scan.pdf"]), ("mixed.combine", ["report.pdf", "photo.jpg"]),
        ("doc.merge", ["notes.md", "readme.txt"]), ("any.zip", ["photo.jpg", "notes.md"]), ("any.targz", ["photo.jpg", "notes.md"]),
        ("audio.merge", ["tone.wav", "song.mp3"]), ("video.merge", ["clip.mp4", "portrait.mov"]),
        ("image.compress.balanced", ["photo.jpg", "screenshot.png"]),
    ]
    for (id, names) in batches {
        let items = names.compactMap { byName[$0] }
        guard items.count == names.count else { continue }
        let work = outDir.appendingPathComponent("batch-\(id)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copies = items.map { i -> InputItem in
            let c = work.appendingPathComponent(i.url.lastPathComponent)
            try? FileManager.default.copyItem(at: i.url, to: c)
            return InputItem(url: c)
        }
        let (result, error) = await runAction(id, copies, quiet: true)
        if let error { fail += 1; failures.append("batch \(id): \(error.localizedDescription)"); print("FAIL batch \(id): \(error.localizedDescription)"); continue }
        var problems: [String] = []
        for o in result?.outputs ?? [] { if let p = await verify(o) { problems.append(p) } }
        if problems.isEmpty && !(result?.outputs.isEmpty ?? true) {
            pass += 1
            print("ok   batch \(id): \((result?.outputs ?? []).map(\.lastPathComponent).joined(separator: ", "))\(result?.summary.map { " — \($0)" } ?? "")")
        } else { fail += 1; failures.append("batch \(id): \(problems)"); print("FAIL batch \(id): \(problems)") }
    }
    // Back-ends of the interactive tool windows.
    func tool(_ name: String, _ input: String, _ body: (InputItem, JobContext) async throws -> Void) async {
        guard let src = byName[input] else { return }
        let work = outDir.appendingPathComponent("tool-\(name)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appendingPathComponent(src.url.lastPathComponent)
        try? FileManager.default.copyItem(at: src.url, to: copy)
        let ctx = JobContext()
        do {
            try await body(InputItem(url: copy), ctx)
            var problems: [String] = []
            for o in ctx.outputs { if let p = await verify(o) { problems.append(p) } }
            if !ctx.outputs.isEmpty && problems.isEmpty {
                pass += 1; print("ok   tool \(name): \(ctx.outputs.map(\.lastPathComponent).joined(separator: ", "))")
            } else { fail += 1; failures.append("tool \(name): \(problems)"); print("FAIL tool \(name): \(problems) outputs=\(ctx.outputs.count)") }
        } catch {
            fail += 1; failures.append("tool \(name): \(error.localizedDescription)"); print("FAIL tool \(name): \(error.localizedDescription)")
        }
    }
    await tool("crop", "photo.jpg") { item, ctx in try await ImageActions.crop(item, rect: CGRect(x: 100, y: 50, width: 800, height: 600), ctx: ctx) }
    await tool("resize", "photo.jpg") { item, ctx in try await ImageActions.resize(item, width: 640, height: 400, ctx: ctx) }
    await tool("add-background", "screenshot.png") { item, ctx in
        var style = BackdropStyle(); style.aspect = .square; style.padding = 80; style.cornerRadius = 24; style.shadow = 30
        let out = ImageRender.addBackground(try ImageKit.load(item.url).image, style: style)!
        try await ImageActions.saveEdited(out, like: item, suffix: "With Background", forcePNG: true, ctx: ctx)
    }
    await tool("annotate", "photo.jpg") { item, ctx in
        let red = RGBA(hex: 0xF0412B)
        let marks: [ImageRender.Annotation] = [
            .init(kind: .arrow(CGPoint(x: 200, y: 200), CGPoint(x: 600, y: 450)), color: red, width: 8),
            .init(kind: .rect(CGRect(x: 900, y: 150, width: 400, height: 300)), color: red, width: 6),
            .init(kind: .text("Look here", CGPoint(x: 220, y: 120)), color: red, width: 8),
            .init(kind: .step(1, CGPoint(x: 1300, y: 700)), color: red, width: 8),
            .init(kind: .pen([CGPoint(x: 100, y: 800), CGPoint(x: 150, y: 760), CGPoint(x: 220, y: 820)]), color: red, width: 6),
            .init(kind: .highlighter([CGPoint(x: 80, y: 880), CGPoint(x: 700, y: 880)]), color: RGBA(hex: 0xF6C343), width: 10),
        ]
        let out = ImageRender.renderAnnotations(try ImageKit.load(item.url).image, marks)!
        try await ImageActions.saveEdited(out, like: item, suffix: "Annotated", ctx: ctx)
    }
    await tool("redact", "screenshot.png") { item, ctx in
        let img = try ImageKit.load(item.url).image
        let lines = try VisionKit.recognizeLines(in: img)
        let boxes = lines.map { ImageRender.Redaction(rect: $0.rect, style: .pixelate) } + [ImageRender.Redaction(rect: CGRect(x: 60, y: 60, width: 200, height: 60), style: .black)]
        let out = ImageRender.renderRedactions(img, boxes)!
        try await ImageActions.saveEdited(out, like: item, suffix: "Redacted", ctx: ctx)
    }
    await tool("edit", "photo.jpg") { item, ctx in
        var a = ImageRender.Adjustments(); a.exposure = 0.4; a.contrast = 1.2; a.saturation = 1.3; a.warmth = 0.3; a.vignette = 0.5
        a.filter = "CIPhotoEffectChrome"; a.quarterTurns = 1; a.flipH = true
        let out = ImageRender.render(try ImageKit.load(item.url).image, adjustments: a)!
        guard out.width == 1000 && out.height == 1600 else { throw TangeloError.failed("rotation produced \(out.width)x\(out.height)") }
        try await ImageActions.saveEdited(out, like: item, suffix: "Edited", ctx: ctx)
    }
    await tool("strip-metadata", "photo.jpg") { item, ctx in
        try await ImageMeta.strip(item, ctx: ctx)
        if let o = ctx.outputs.first, ImageMeta.location(for: o) != nil { throw TangeloError.failed("GPS still present") }
    }
    await tool("strip-location", "photo.heic") { item, ctx in
        try await ImageMeta.strip(item, onlyLocation: true, ctx: ctx)
        if let o = ctx.outputs.first, ImageMeta.location(for: o) != nil { throw TangeloError.failed("GPS still present") }
    }
    await tool("pdf-protect-unlock", "report.pdf") { item, ctx in
        try await PDFActions.protect(item, password: "tangelo", ctx: ctx)
        guard let locked = ctx.outputs.first, PDFActions.isEncrypted(locked) else { throw TangeloError.failed("not encrypted") }
        try await PDFActions.unlock(InputItem(url: locked), password: "tangelo", ctx: ctx)
        guard let open = ctx.outputs.last, !PDFActions.isEncrypted(open) else { throw TangeloError.failed("still encrypted") }
    }
    await tool("trim-audio", "tone.wav") { item, ctx in try await AudioActions.trim(item, start: 0.5, end: 2.0, ctx: ctx) }
    await tool("trim-mp3", "song.mp3") { item, ctx in try await AudioActions.trim(item, start: 1, end: 3, ctx: ctx) }
    await tool("trim-video", "clip.mp4") { item, ctx in try await AudioActions.trim(item, start: 0.5, end: 2.5, ctx: ctx) }
    await tool("trim-webm", "web.webm") { item, ctx in try await AudioActions.trim(item, start: 0.2, end: 1.5, ctx: ctx) }

    print("\n\(pass) passed, \(fail) failed")
    for f in failures { print("  ✗ \(f)") }
    return fail == 0
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
switch command {
case "menu":
    let items = args.dropFirst().map { InputItem(url: URL(fileURLWithPath: $0)) }
    guard !items.isEmpty else { usage() }
    for i in items { print("\(i.url.lastPathComponent): \(i.kind.rawValue) / \(i.format) / \(ByteFormat.string(i.size))") }
    describe(Catalog.pages(for: items))
case "run":
    guard args.count >= 3 else { usage() }
    let items = args.dropFirst(2).map { InputItem(url: URL(fileURLWithPath: $0)) }
    let (result, error) = await runAction(args[1], items)
    if let error { print("error: \(error.localizedDescription)"); exit(1) }
    for o in result?.outputs ?? [] { print(o.path) }
    if let s = result?.summary { print(s) }
    if let t = result?.clipboardText { print(t) }
    for f in result?.failures ?? [] { print("failed: \(f.name): \(f.message)") }
case "test-all":
    let dir = args.count > 1 ? URL(fileURLWithPath: args[1]) : FileManager.default.temporaryDirectory.appendingPathComponent("tangelo-test")
    exit(await testAll(dir: dir) ? 0 : 1)
case "selftest-webp":
    exit(selftestWebP() ? 0 : 1)
case "job":
    exit(await Worker.run())
case "qa":
    let dir = args.count > 1 ? URL(fileURLWithPath: args[1]) : FileManager.default.temporaryDirectory.appendingPathComponent("tangelo-qa")
    var qa = QA(root: dir)
    exit(await qa.run() ? 0 : 1)
default:
    usage()
}
