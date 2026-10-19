import CoreGraphics
import Foundation

public struct RunResult: Sendable {
    public var outputs: [URL] = []
    public var summary: String? = nil
    /// Text to place on the clipboard (Copy Text actions).
    public var clipboardText: String? = nil
    public var failures: [(name: String, message: String)] = []
    public init() {}
}

public enum Runner {
    static let batchActions: Set<String> = [
        "image.merge.pdf", "image.merge.gif", "image.stitch.v", "image.stitch.h", "pdf.merge", "video.merge",
        "audio.merge", "doc.merge", "mixed.combine", "any.zip", "any.targz",
    ]

    /// Runs a quick (non-interactive) action. Per-file actions continue past individual failures.
    public static func run(_ actionID: String, items: [InputItem], ctx: JobContext) async throws -> RunResult {
        var result = RunResult()
        let outer = ctx.progressHandler

        if batchActions.contains(actionID) {
            try await runBatch(actionID, items: items, ctx: ctx)
            result.outputs = ctx.outputs
            result.summary = ctx.summary
            return result
        }

        var texts: [String] = []
        var lastError: Error?
        let totalBefore = items.reduce(Int64(0)) { $0 + ($1.size > 0 ? $1.size : ByteFormat.size(of: $1.url)) }
        for (i, item) in items.enumerated() {
            try ctx.check()
            let n = items.count
            ctx.progressHandler = { f, d in
                outer?((Double(i) + (f ?? 0)) / Double(n), n > 1 ? "\(i) of \(n) saved" : d)
            }
            ctx.report(0)
            do {
                if let text = try await runOne(actionID, item: item, ctx: ctx) { texts.append(text) }
            } catch TangeloError.cancelled {
                throw TangeloError.cancelled
            } catch {
                if ctx.isCancelled { throw TangeloError.cancelled }
                lastError = error
                result.failures.append((item.url.lastPathComponent, error.localizedDescription))
            }
        }
        ctx.progressHandler = outer
        result.outputs = ctx.outputs
        if !texts.isEmpty {
            if actionID == "doc.stats" { result.summary = texts.joined(separator: "\n") }
            else { result.clipboardText = texts.joined(separator: "\n\n") }
        }
        if result.summary == nil {
            if actionID.contains(".compress."), items.count > 1, !result.outputs.isEmpty {
                let after = result.outputs.reduce(Int64(0)) { $0 + ByteFormat.size(of: $1) }
                let before = totalBefore - items.filter { i in result.failures.contains { $0.name == i.url.lastPathComponent } }
                    .reduce(Int64(0)) { $0 + $1.size }
                result.summary = ByteFormat.savings(from: before, to: after)
            } else {
                result.summary = ctx.summary
            }
        }
        if result.outputs.isEmpty && result.clipboardText == nil && actionID != "doc.stats", let lastError {
            throw lastError
        }
        return result
    }

    static func parts(_ id: String) -> (String, String, String) {
        let p = id.split(separator: ".", maxSplits: 2).map(String.init)
        return (p.count > 0 ? p[0] : "", p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "")
    }

    static func level(_ s: String) -> CompressLevel { CompressLevel(rawValue: s) ?? .balanced }

    /// Returns text for Copy Text / Words actions.
    static func runOne(_ id: String, item: InputItem, ctx: JobContext) async throws -> String? {
        let (kind, verb, arg) = parts(id)
        switch (kind, verb) {
        // Images
        case ("image", "to"):
            if arg == "mp4" {
                try await FFmpeg.convert(item, ext: "mp4", args: ["-movflags", "+faststart", "-pix_fmt", "yuv420p",
                                                                  "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", "libx264", "-crf", "20"], ctx: ctx)
            } else {
                guard let f = ImageFormat(rawValue: arg) else { throw TangeloError.unsupported("Unknown image format.") }
                try await ImageActions.convert(item, to: f, ctx: ctx)
            }
        case ("image", "compress"): try await ImageActions.compress(item, level: level(arg), ctx: ctx)
        case ("image", "scale"): try await ImageActions.resize(item, scale: (Double(arg) ?? 50) / 100, ctx: ctx)
        case ("image", "rotate"): try await ImageActions.rotate(item, quarterTurns: Int(arg) ?? 1, ctx: ctx)
        case ("image", "flip"): try await ImageActions.flip(item, horizontal: arg == "h", ctx: ctx)
        case ("image", "gray"): try await ImageActions.grayscale(item, ctx: ctx)
        case ("image", "removebg"):
            let loaded = try ImageKit.load(item.url)
            let cut = try VisionKit.removeBackground(loaded.image)
            try await ctx.produce(ctx.destination(for: item.url, ext: "png", suffix: "No Background")) { tmp in
                try ImageKit.write(cut, to: tmp, format: .png, quality: 1, settings: ctx.settings)
            }
        case ("image", "ocr"), ("image", "copytext"):
            let text = try VisionKit.recognizeText(in: try ImageKit.load(item.url).image)
            guard !text.isEmpty else { throw TangeloError.failed("No text found in \(item.url.lastPathComponent).") }
            if verb == "copytext" { return text }
            if arg == "docx" {
                try await DocActions.write(DocActions.plainAttributed(text), like: item, format: .docx, ctx: ctx)
            } else {
                try await ctx.produce(ctx.destination(for: item.url, ext: "txt")) { try text.write(to: $0, atomically: false, encoding: .utf8) }
            }
        case ("image", "metadata"): try await ImageMeta.strip(item, ctx: ctx)

        // PDF
        case ("pdf", "to"):
            if let img = ImageFormat(rawValue: arg) { try await PDFActions.toImages(item, format: img, ctx: ctx) }
            else if arg == "txt" { try await PDFActions.toText(item, ctx: ctx) }
            else if let doc = DocFormat(rawValue: arg) { try await PDFActions.toDocument(item, format: doc, ctx: ctx) }
            else { throw TangeloError.unsupported("Unknown format.") }
        case ("pdf", "compress"): try await PDFActions.compress(item, level: level(arg), ctx: ctx)
        case ("pdf", "rotate"): try await PDFActions.rotate(item, quarterTurns: Int(arg) ?? 1, ctx: ctx)
        case ("pdf", "split"): try await PDFActions.split(item, ctx: ctx)
        case ("pdf", "ocr"): try await PDFActions.makeSearchable(item, ctx: ctx)
        case ("pdf", "copytext"): return try PDFActions.extractText(item, ctx: ctx)

        // Video
        case ("video", "to"): try await VideoActions.convert(item, to: arg, ctx: ctx)
        case ("video", "compress"): try await VideoActions.compress(item, level: level(arg), ctx: ctx)
        case ("video", "mute"): try await VideoActions.mute(item, ctx: ctx)
        case ("video", "rotate"): try await VideoActions.rotate(item, quarterTurns: Int(arg) ?? 1, ctx: ctx)
        case ("video", "resize"): try await VideoActions.resize(item, shortSide: Int(arg) ?? 720, ctx: ctx)
        case ("video", "speed"): try await VideoActions.speed(item, factor: Double(arg) ?? 2, ctx: ctx)
        case ("video", "snapshot"): try await VideoActions.snapshot(item, ctx: ctx)

        // Audio
        case ("audio", "to"): try await AudioActions.convert(item, to: arg, ctx: ctx)
        case ("audio", "compress"): try await AudioActions.compress(item, level: level(arg), ctx: ctx)
        case ("audio", "normalize"): try await AudioActions.normalize(item, ctx: ctx)
        case ("audio", "mono"): try await AudioActions.mono(item, ctx: ctx)
        case ("audio", "reverse"): try await AudioActions.reverse(item, ctx: ctx)
        case ("audio", "speed"): try await AudioActions.speed(item, factor: Double(arg) ?? 2, ctx: ctx)

        // Documents & data
        case ("doc", "to"):
            guard let f = DocFormat(rawValue: arg) else { throw TangeloError.unsupported("Unknown document format.") }
            try await DocActions.convert(item, to: f, ctx: ctx)
        case ("doc", "stats"): return try await DocActions.stats(item)
        case ("doc", "copytext"):
            return try await MainActor.run { try DocActions.read(item).string }
        case ("data", "to"): try await DataActions.convert(item, to: arg, ctx: ctx)
        case ("data", "json"): try await DataActions.reformatJSON(item, pretty: arg == "pretty", ctx: ctx)
        case ("archive", "extract"): try await ArchiveActions.extract(item, ctx: ctx)
        default:
            throw TangeloError.unsupported("Unknown action \(id).")
        }
        return nil
    }

    static func runBatch(_ id: String, items: [InputItem], ctx: JobContext) async throws {
        switch id {
        case "image.merge.pdf", "mixed.combine": try await ImageActions.combineToPDF(items, ctx: ctx)
        case "image.merge.gif": try await ImageActions.animatedGIF(items, ctx: ctx)
        case "image.stitch.v": try await ImageActions.stitch(items, vertical: true, ctx: ctx)
        case "image.stitch.h": try await ImageActions.stitch(items, vertical: false, ctx: ctx)
        case "pdf.merge": try await PDFActions.merge(items, ctx: ctx)
        case "video.merge": try await VideoActions.merge(items, ctx: ctx)
        case "audio.merge": try await AudioActions.merge(items, ctx: ctx)
        case "doc.merge": try await DocActions.mergeToPDF(items, ctx: ctx)
        case "any.zip": try await ArchiveActions.zip(items, ctx: ctx)
        case "any.targz": try await ArchiveActions.tarGz(items, ctx: ctx)
        default: throw TangeloError.unsupported("Unknown action \(id).")
        }
    }
}
