import Foundation

/// Interactive tools that open a window instead of running immediately.
public enum ToolKind: String, Sendable {
    case crop, addBackground, annotate, redact, edit, metadata, resize, trim, pdfProtect, pdfUnlock
}

public struct Action: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String?
    public let verb: String
    public let tool: ToolKind?

    public init(_ id: String, _ title: String, symbol: String? = nil, verb: String? = nil, tool: ToolKind? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.verb = verb ?? "Converting to \(title)"
        self.tool = tool
    }
}

public enum MenuEntry: Sendable {
    case action(Action)
    /// A wedge that opens a sub-ring when hovered; dropping on it runs `primary`.
    case group(title: String, symbol: String?, children: [Action], primary: Action)

    public var title: String {
        switch self {
        case .action(let a): return a.title
        case .group(let t, _, _, _): return t
        }
    }

    public var symbol: String? {
        switch self {
        case .action(let a): return a.symbol
        case .group(_, let s, _, _): return s
        }
    }
}

public struct MenuPage: Sendable {
    public let title: String
    public let entries: [MenuEntry]
}

public enum Catalog {
    // MARK: Building blocks

    static func to(_ kind: String, _ fmt: String, _ title: String? = nil) -> MenuEntry {
        let t = title ?? fmt.uppercased()
        return .action(Action("\(kind).to.\(fmt)", t, verb: "Converting to \(t)"))
    }

    static func tool(_ id: String, _ title: String, _ symbol: String, verb: String, tool: ToolKind? = nil) -> MenuEntry {
        .action(Action(id, title, symbol: symbol, verb: verb, tool: tool))
    }

    static func compressGroup(_ kind: String) -> MenuEntry {
        let children = CompressLevel.allCases.map {
            Action("\(kind).compress.\($0.rawValue)", $0.title.uppercased(), symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing")
        }
        return .group(title: "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", children: children, primary: children[1])
    }

    static func rotateGroup(_ kind: String, flips: Bool) -> MenuEntry {
        var children = [
            Action("\(kind).rotate.1", "RIGHT", symbol: "rotate.right", verb: "Rotating"),
            Action("\(kind).rotate.3", "LEFT", symbol: "rotate.left", verb: "Rotating"),
            Action("\(kind).rotate.2", "180°", symbol: "arrow.trianglehead.2.clockwise.rotate.90", verb: "Rotating"),
        ]
        if flips {
            children.append(Action("\(kind).flip.h", "FLIP H", symbol: "arrow.left.and.right", verb: "Flipping"))
            children.append(Action("\(kind).flip.v", "FLIP V", symbol: "arrow.up.and.down", verb: "Flipping"))
        }
        return .group(title: "ROTATE", symbol: "rotate.right", children: children, primary: children[0])
    }

    static let zip = tool("any.zip", "ZIP", "doc.zipper", verb: "Zipping")
    static let tarGz = tool("any.targz", "TAR.GZ", "archivebox", verb: "Archiving")

    /// Takes the formats in `preferred` (minus the source formats) and fills a page.
    static func formats(_ kind: String, _ preferred: [String], excluding: Set<String>, titles: [String: String] = [:],
                        limit: Int = 10) -> [MenuEntry] {
        preferred.filter { !excluding.contains($0) }.prefix(limit).map { to(kind, $0, titles[$0]) }
    }

    // MARK: Pages

    public static func pages(for items: [InputItem], settings: EngineSettings = EngineSettings()) -> [MenuPage] {
        guard !items.isEmpty else { return [] }
        let kinds = Set(items.map(\.kind))
        let sources = Set(items.map(\.format)).union(items.map { $0.format == "heic" ? "heics" : $0.format })
        let many = items.count > 1
        let ff = settings.hasFFmpeg

        guard kinds.count == 1, let kind = kinds.first else {
            if kinds.isSubset(of: [.image, .pdf]) {
                return [MenuPage(title: "MERGE", entries: [tool("mixed.combine", "PDF", "doc.richtext", verb: "Combining into PDF"), zip, tarGz])]
            }
            return [MenuPage(title: "ARCHIVE", entries: [zip, tarGz])]
        }

        switch kind {
        case .image:
            let primary = ["jpg", "png", "heic", "webp", "avif", "pdf", "tiff", "gif"]
            let extra = ["bmp", "ico", "icns", "jp2", "psd", "tga"]
            let excl = sources
            var convert = formats("image", primary, excluding: excl, titles: ["jpg": "JPG"])
            if convert.count < 8, let fill = extra.first(where: { !excl.contains($0) }) { convert.append(to("image", fill)) }
            let used = Set(convert.compactMap { e -> String? in if case .action(let a) = e { return a.id.components(separatedBy: ".").last } else { return nil } })
            var more = formats("image", extra, excluding: excl.union(used))
            more.append(tool("image.ocr.txt", "TXT", "text.viewfinder", verb: "Reading text"))
            more.append(tool("image.ocr.docx", "DOCX", "doc.text", verb: "Reading text"))
            if sources == ["gif"], ff { more.append(to("image", "mp4", "MP4")) }

            var pages = [MenuPage(title: "CONVERT", entries: convert), MenuPage(title: "MORE", entries: more)]
            if many {
                pages.append(MenuPage(title: "TOOLS", entries: [
                    compressGroup("image"),
                    .group(title: "RESIZE", symbol: "arrow.up.left.and.arrow.down.right", children: [
                        Action("image.scale.75", "75%", symbol: "arrow.down.right.and.arrow.up.left", verb: "Resizing"),
                        Action("image.scale.50", "50%", symbol: "arrow.down.right.and.arrow.up.left", verb: "Resizing"),
                        Action("image.scale.25", "25%", symbol: "arrow.down.right.and.arrow.up.left", verb: "Resizing"),
                    ], primary: Action("image.scale.50", "50%", verb: "Resizing")),
                    rotateGroup("image", flips: true),
                    tool("image.gray", "GRAYSCALE", "circle.lefthalf.filled", verb: "Converting to grayscale"),
                    tool("image.removebg", "REMOVE BG", "person.crop.rectangle", verb: "Removing background"),
                    tool("image.metadata.strip", "STRIP INFO", "tag.slash", verb: "Removing metadata"),
                ]))
                pages.append(MenuPage(title: "MERGE", entries: [
                    tool("image.merge.pdf", "PDF", "doc.richtext", verb: "Combining into PDF"),
                    tool("image.merge.gif", "GIF", "photo.stack", verb: "Making GIF"),
                    tool("image.stitch.v", "STITCH ↓", "rectangle.split.1x2", verb: "Stitching"),
                    tool("image.stitch.h", "STITCH →", "rectangle.split.2x1", verb: "Stitching"),
                    zip,
                ]))
            } else {
                pages.append(MenuPage(title: "TOOLS", entries: [
                    compressGroup("image"),
                    tool("image.tool.metadata", "METADATA", "tag", verb: "Metadata", tool: .metadata),
                    tool("image.tool.edit", "EDIT", "slider.horizontal.3", verb: "Editing", tool: .edit),
                    tool("image.tool.annotate", "ANNOTATE", "pencil.tip.crop.circle", verb: "Annotating", tool: .annotate),
                    tool("image.tool.addbg", "ADD BG", "photo.on.rectangle", verb: "Adding background", tool: .addBackground),
                    tool("image.tool.crop", "CROP", "crop", verb: "Cropping", tool: .crop),
                    tool("image.tool.redact", "REDACT", "eye.slash", verb: "Redacting", tool: .redact),
                ]))
                pages.append(MenuPage(title: "EXTRAS", entries: [
                    tool("image.removebg", "REMOVE BG", "person.crop.rectangle", verb: "Removing background"),
                    .group(title: "RESIZE", symbol: "arrow.up.left.and.arrow.down.right", children: [
                        Action("image.scale.50", "50%", symbol: "arrow.down.right.and.arrow.up.left", verb: "Resizing"),
                        Action("image.scale.25", "25%", symbol: "arrow.down.right.and.arrow.up.left", verb: "Resizing"),
                        Action("image.scale.200", "200%", symbol: "arrow.up.left.and.arrow.down.right", verb: "Resizing"),
                        Action("image.tool.resize", "CUSTOM", symbol: "ruler", verb: "Resizing", tool: .resize),
                    ], primary: Action("image.tool.resize", "CUSTOM", verb: "Resizing", tool: .resize)),
                    rotateGroup("image", flips: true),
                    tool("image.copytext", "COPY TEXT", "text.viewfinder", verb: "Reading text"),
                    tool("image.gray", "GRAYSCALE", "circle.lefthalf.filled", verb: "Converting to grayscale"),
                    zip,
                ]))
            }
            return pages

        case .pdf:
            let convert = ["jpg", "png", "docx", "txt", "rtf", "html", "heic", "tiff"].map { to("pdf", $0, $0 == "jpg" ? "JPG" : nil) }
            var more = ["md", "odt", "doc", "webp", "avif"].map { to("pdf", $0) }
            if !many { more += [tool("doc.stats", "WORDS", "textformat.abc", verb: "Counting words"), zip] }
            var tools: [MenuEntry] = []
            if many { tools.append(tool("pdf.merge", "MERGE", "square.stack.3d.down.right", verb: "Merging PDFs")) }
            tools += [
                compressGroup("pdf"),
                rotateGroup("pdf", flips: false),
            ]
            if !many {
                tools += [
                    tool("pdf.split", "SPLIT", "scissors", verb: "Splitting pages"),
                    tool("pdf.ocr", "OCR", "doc.text.viewfinder", verb: "Making searchable"),
                    tool("pdf.tool.protect", "PROTECT", "lock", verb: "Protecting", tool: .pdfProtect),
                    tool("pdf.tool.unlock", "UNLOCK", "lock.open", verb: "Unlocking", tool: .pdfUnlock),
                    tool("pdf.copytext", "COPY TEXT", "text.viewfinder", verb: "Copying text"),
                ]
            } else {
                tools.append(zip)
            }
            return [MenuPage(title: "CONVERT", entries: convert), MenuPage(title: "MORE", entries: more),
                    MenuPage(title: "TOOLS", entries: tools)]

        case .video:
            var convert = ["mp4", "mov", "gif", "m4a"] + (ff ? ["mp3", "webm", "mkv"] : []) + ["wav"]
            convert = convert.filter { !sources.contains($0) }
            var more = ["hevc", "prores", "m4v", "flac", "aiff", "aac"] + (ff ? ["avi", "opus"] : [])
            more = more.filter { !sources.contains($0) }
            func entry(_ f: String) -> MenuEntry {
                let audio = ["m4a", "mp3", "wav", "flac", "aiff", "aac", "opus"].contains(f)
                return audio ? to("audio", f) : to("video", f, f == "hevc" ? "HEVC" : (f == "prores" ? "PRORES" : nil))
            }
            var tools: [MenuEntry] = []
            if !many { tools.append(tool("video.tool.trim", "TRIM", "timeline.selection", verb: "Trimming", tool: .trim)) }
            tools += [
                compressGroup("video"),
                tool("video.mute", "MUTE", "speaker.slash", verb: "Removing audio"),
                rotateGroup("video", flips: false),
                .group(title: "RESIZE", symbol: "arrow.up.left.and.arrow.down.right", children: [480, 720, 1080, 2160].map {
                    Action("video.resize.\($0)", $0 == 2160 ? "4K" : "\($0)P", symbol: "arrow.up.left.and.arrow.down.right", verb: "Resizing")
                }, primary: Action("video.resize.720", "720P", verb: "Resizing")),
                speedGroup("video"),
                tool("video.snapshot", "SNAPSHOT", "camera", verb: "Saving frame"),
            ]
            if many { tools.append(tool("video.merge", "MERGE", "square.stack.3d.down.right", verb: "Merging videos")) }
            else { tools.append(zip) }
            return [MenuPage(title: "CONVERT", entries: convert.map(entry)), MenuPage(title: "MORE", entries: more.map(entry)),
                    MenuPage(title: "TOOLS", entries: tools)]

        case .audio:
            let excl = sources
            let convert = formats("audio", (ff ? ["mp3"] : []) + ["m4a", "wav", "aiff", "flac", "alac"] + (ff ? ["opus", "ogg"] : []), excluding: excl)
            let more = formats("audio", ["caf", "aac", "m4r"] + (ff ? ["ac3", "wma"] : []), excluding: excl, titles: ["m4r": "RINGTONE"])
            var tools: [MenuEntry] = []
            if !many { tools.append(tool("audio.tool.trim", "TRIM", "timeline.selection", verb: "Trimming", tool: .trim)) }
            tools += [
                compressGroup("audio"),
                tool("audio.normalize", "NORMALIZE", "waveform", verb: "Normalizing"),
                tool("audio.mono", "MONO", "speaker.wave.1", verb: "Converting to mono"),
                tool("audio.reverse", "REVERSE", "backward", verb: "Reversing"),
                speedGroup("audio"),
            ]
            tools.append(many ? tool("audio.merge", "MERGE", "square.stack.3d.down.right", verb: "Merging audio") : zip)
            return [MenuPage(title: "CONVERT", entries: convert), MenuPage(title: "MORE", entries: more),
                    MenuPage(title: "TOOLS", entries: tools)]

        case .document:
            let all = ["pdf", "docx", "rtf", "txt", "html", "odt", "md", "doc", "rtfd", "webarchive"]
            let convert = all.filter { !sources.contains($0) }.map { to("doc", $0, $0 == "webarchive" ? "WEB" : nil) }
            var tools: [MenuEntry] = [tool("doc.stats", "WORDS", "textformat.abc", verb: "Counting words"),
                                      tool("doc.copytext", "COPY TEXT", "doc.on.clipboard", verb: "Copying text")]
            if many { tools.insert(tool("doc.merge", "MERGE", "square.stack.3d.down.right", verb: "Merging into PDF"), at: 0) }
            tools.append(zip)
            return [MenuPage(title: "CONVERT", entries: convert), MenuPage(title: "TOOLS", entries: tools)]

        case .data:
            let convert = ["csv", "tsv", "json", "xlsx", "html", "md"].filter { !sources.contains($0) }.map { to("data", $0) }
            var tools: [MenuEntry] = []
            if sources == ["json"] {
                tools += [tool("data.json.pretty", "PRETTIFY", "text.alignleft", verb: "Formatting JSON"),
                          tool("data.json.minify", "MINIFY", "arrow.right.and.line.vertical.and.arrow.left", verb: "Minifying JSON")]
            }
            tools.append(zip)
            return [MenuPage(title: "CONVERT", entries: convert), MenuPage(title: "TOOLS", entries: tools)]

        case .archive:
            return [MenuPage(title: "ARCHIVE", entries: [tool("archive.extract", "EXTRACT", "arrow.up.bin", verb: "Extracting")]
                + (sources.contains("zip") ? [] : [zip]))]

        case .folder, .other:
            return [MenuPage(title: "ARCHIVE", entries: [zip, tarGz])]
        }
    }

    static func speedGroup(_ kind: String) -> MenuEntry {
        let factors: [(String, String)] = [("0.5", "0.5×"), ("0.75", "0.75×"), ("1.5", "1.5×"), ("2", "2×"), ("4", "4×")]
        let children = factors.map { Action("\(kind).speed.\($0.0)", $0.1, symbol: "gauge.with.dots.needle.67percent", verb: "Changing speed") }
        return .group(title: "SPEED", symbol: "gauge.with.dots.needle.67percent", children: children, primary: children[3])
    }

    /// Finds an action by id anywhere in the pages (including inside groups).
    public static func find(_ id: String, in pages: [MenuPage]) -> Action? {
        for p in pages {
            for e in p.entries {
                switch e {
                case .action(let a) where a.id == id: return a
                case .group(_, _, let children, let primary):
                    if primary.id == id { return primary }
                    if let a = children.first(where: { $0.id == id }) { return a }
                default: break
                }
            }
        }
        return nil
    }

    public static func allActions(in pages: [MenuPage]) -> [Action] {
        var out: [Action] = []
        var seen = Set<String>()
        for p in pages {
            for e in p.entries {
                let list: [Action]
                switch e {
                case .action(let a): list = [a]
                case .group(_, _, let children, let primary): list = children + [primary]
                }
                for a in list where seen.insert(a.id).inserted { out.append(a) }
            }
        }
        return out
    }
}
