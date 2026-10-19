import AppKit
import Foundation
import UniformTypeIdentifiers

public enum DocFormat: String, CaseIterable, Sendable {
    case pdf, docx, doc, rtf, rtfd, txt, html, odt, md, webarchive

    public var title: String { self == .webarchive ? "WEB" : rawValue.uppercased() }

    var documentType: NSAttributedString.DocumentType? {
        switch self {
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .rtf: return .rtf
        case .rtfd: return .rtfd
        case .txt: return .plain
        case .html: return .html
        case .odt: return .openDocument
        case .webarchive: return .webArchive
        case .pdf, .md: return nil
        }
    }
}

public enum DocActions {
    // MARK: Reading

    static func readText(_ url: URL) throws -> String {
        var enc = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        if let s = try? String(contentsOf: url, encoding: .windowsCP1252) { return s }
        throw TangeloError.unsupported("Couldn't read the text in \(url.lastPathComponent).")
    }

    public static func plainAttributed(_ text: String, monospaced: Bool = false) -> NSAttributedString {
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular) : NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = monospaced ? 1 : 2
        style.paragraphSpacing = monospaced ? 0 : 4
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
    }

    @MainActor
    public static func read(_ item: InputItem) throws -> NSAttributedString {
        switch item.format {
        case "md":
            let html = Markdown.toHTMLDocument(try readText(item.url), title: item.baseName)
            return try fromHTML(html, baseURL: item.url.deletingLastPathComponent())
        case "txt":
            return plainAttributed(try readText(item.url))
        case "html":
            return try fromHTML(try readText(item.url), baseURL: item.url.deletingLastPathComponent())
        case "rtf", "rtfd", "doc", "docx", "odt", "webarchive":
            var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let t = docType(for: item.format) { opts[.documentType] = t }
            do {
                return try NSAttributedString(url: item.url, options: opts, documentAttributes: nil)
            } catch {
                throw TangeloError.unsupported("Couldn't read \(item.url.lastPathComponent).")
            }
        default:
            // Source code and other plain text.
            return plainAttributed(try readText(item.url), monospaced: item.type.conforms(to: .sourceCode))
        }
    }

    static func docType(for format: String) -> NSAttributedString.DocumentType? {
        switch format {
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "doc": return .docFormat
        case "docx": return .officeOpenXML
        case "odt": return .openDocument
        case "webarchive": return .webArchive
        default: return nil
        }
    }

    @MainActor
    static func fromHTML(_ html: String, baseURL: URL?) throws -> NSAttributedString {
        var opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { opts[.baseURL] = baseURL }
        guard let data = html.data(using: .utf8),
              let s = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) else {
            throw TangeloError.failed("Couldn't read the HTML.")
        }
        return s
    }

    // MARK: Converting

    public static func convert(_ item: InputItem, to format: DocFormat, ctx: JobContext) async throws {
        if item.format == "md" && format == .html {
            let html = Markdown.toHTMLDocument(try readText(item.url), title: item.baseName)
            try await ctx.produce(ctx.destination(for: item.url, ext: "html")) { try html.write(to: $0, atomically: false, encoding: .utf8) }
            return
        }
        let attr = try await MainActor.run { try read(item) }
        try await write(attr, like: item, format: format, ctx: ctx)
    }

    public static func write(_ attr: NSAttributedString, like item: InputItem, format: DocFormat, ctx: JobContext,
                             suffix: String? = nil) async throws {
        let dest = ctx.destination(for: item.url, ext: format.rawValue, suffix: suffix)
        try await ctx.produce(dest) { tmp in try await write(attr, format: format, to: tmp) }
    }

    public static func write(_ attr: NSAttributedString, format: DocFormat, to url: URL) async throws {
        switch format {
        case .pdf:
            try await MainActor.run { try renderPDF(attr, to: url) }
        case .txt:
            try attr.string.write(to: url, atomically: false, encoding: .utf8)
        case .md:
            try markdown(from: attr).write(to: url, atomically: false, encoding: .utf8)
        case .rtfd:
            let wrapper = try attr.fileWrapper(from: NSRange(location: 0, length: attr.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        case .html, .webarchive:
            let data = try await MainActor.run {
                try attr.data(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [.documentType: format.documentType!, .characterEncoding: String.Encoding.utf8.rawValue])
            }
            try data.write(to: url)
        default:
            let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                     documentAttributes: [.documentType: format.documentType!])
            try data.write(to: url)
        }
    }

    /// Paginates rich text onto Letter/A4 pages with real line breaks (no cut-off lines).
    @MainActor
    public static func renderPDF(_ attr: NSAttributedString, to url: URL) throws {
        let usesLetter = ["US", "CA", "MX", "PH", "CL", "CO"].contains(Locale.current.region?.identifier ?? "US")
        let paper = usesLetter ? NSSize(width: 612, height: 792) : NSSize(width: 595, height: 842)
        let margin: CGFloat = 56

        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let printable = NSMutableAttributedString(attributedString: attr)
        // Make sure text is dark on white even when the Mac is in Dark Mode.
        printable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: printable.length)) { value, range, _ in
            if value == nil { printable.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        let width = paper.width - 2 * margin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height - 2 * margin))
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(printable)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw TangeloError.failed("Couldn't create the PDF.")
        }
    }

    // MARK: Markdown export

    public static func markdown(from attr: NSAttributedString) -> String {
        let ns = attr.string as NSString
        guard ns.length > 0 else { return "" }
        // The most common font size is the body size.
        var sizes: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { v, r, _ in
            if let f = v as? NSFont { sizes[f.pointSize.rounded(), default: 0] += r.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        let markerRegex = try! NSRegularExpression(pattern: #"^\t*(?:[•◦▪●○■\-–]|\d+[.)]|[a-zA-Z][.)])\t"#)
        var out: [String] = []

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { sub, range, _, _ in
            guard let sub else { return }
            if sub.trimmingCharacters(in: .whitespaces).isEmpty { return }
            let style = attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            var maxSize: CGFloat = 0
            var allBold = true
            attr.enumerateAttribute(.font, in: range) { v, r, _ in
                guard let f = v as? NSFont else { return }
                let text = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                if text.isEmpty { return }
                maxSize = max(maxSize, f.pointSize)
                if !f.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
            }
            var prefix = ""
            var heading = false
            var contentRange = range
            if let lists = style?.textLists, let last = lists.last {
                prefix = String(repeating: "  ", count: max(0, lists.count - 1)) + (last.isOrdered ? "1. " : "- ")
                if let m = markerRegex.firstMatch(in: sub, range: NSRange(location: 0, length: (sub as NSString).length)) {
                    contentRange = NSRange(location: range.location + m.range.length, length: range.length - m.range.length)
                }
            } else if let m = markerRegex.firstMatch(in: sub, range: NSRange(location: 0, length: (sub as NSString).length)) {
                let marker = (sub as NSString).substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
                prefix = marker.first?.isNumber == true ? "1. " : "- "
                contentRange = NSRange(location: range.location + m.range.length, length: range.length - m.range.length)
            } else if maxSize >= body * 1.6 {
                prefix = "# "; heading = true
            } else if maxSize >= body * 1.3 {
                prefix = "## "; heading = true
            } else if maxSize >= body * 1.12 && allBold {
                prefix = "### "; heading = true
            }
            var line = ""
            attr.enumerateAttributes(in: contentRange) { attrs, r, _ in
                var text = ns.substring(with: r)
                if text.isEmpty { return }
                text = text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
                    .replacingOccurrences(of: "\u{2028}", with: "  \n")
                let lead = String(text.prefix(while: { $0 == " " }))
                let trail = String(text.reversed().prefix(while: { $0 == " " }))
                var core = text.trimmingCharacters(in: .whitespaces)
                if !core.isEmpty, !heading, let f = attrs[.font] as? NSFont {
                    let traits = f.fontDescriptor.symbolicTraits
                    if traits.contains(.monoSpace) { core = "`\(core)`" }
                    else if traits.contains(.bold) && traits.contains(.italic) { core = "***\(core)***" }
                    else if traits.contains(.bold) { core = "**\(core)**" }
                    else if traits.contains(.italic) { core = "*\(core)*" }
                }
                if !core.isEmpty, let link = attrs[.link] {
                    let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    if !href.isEmpty { core = "[\(core)](\(href))" }
                }
                line += lead + core + trail
            }
            out.append(prefix + line.trimmingCharacters(in: .whitespaces))
        }
        // Keep list items tight, separate everything else with blank lines.
        var md = ""
        for (i, l) in out.enumerated() {
            let isItem = l.hasPrefix("- ") || l.hasPrefix("1. ") || l.hasPrefix("  ")
            let prevItem = i > 0 && (out[i - 1].hasPrefix("- ") || out[i - 1].hasPrefix("1. ") || out[i - 1].hasPrefix("  "))
            if i > 0 { md += (isItem && prevItem) ? "\n" : "\n\n" }
            md += l
        }
        return md + "\n"
    }

    // MARK: Tools

    public static func stats(_ item: InputItem) async throws -> String {
        let text: String
        if item.kind == .pdf {
            text = try PDFActions.extractText(item, ctx: JobContext())
        } else {
            text = try await MainActor.run { try read(item).string }
        }
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let chars = text.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        let minutes = max(1, Int((Double(words) / 230).rounded()))
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let w = f.string(from: NSNumber(value: words)) ?? "\(words)"
        let c = f.string(from: NSNumber(value: chars)) ?? "\(chars)"
        return "\(w) words · \(c) characters · \(lines) lines · ~\(minutes) min read"
    }

    public static func mergeToPDF(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        let combined = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            try ctx.check()
            let a = try await MainActor.run { try read(item) }
            combined.append(a)
            if i < items.count - 1 { combined.append(NSAttributedString(string: "\u{000C}")) } // page break
        }
        let dest = ctx.destination(named: first.baseName + " Merged", ext: "pdf", near: first.url)
        try await ctx.produce(dest) { tmp in try await write(combined, format: .pdf, to: tmp) }
    }
}
