import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Quartz

public enum PDFActions {
    static func open(_ item: InputItem) throws -> PDFDocument {
        guard let doc = PDFDocument(url: item.url) else {
            throw TangeloError.unsupported("Couldn't open \(item.url.lastPathComponent).")
        }
        if doc.isLocked { throw TangeloError.failed("\(item.url.lastPathComponent) is password-protected. Use Unlock first.") }
        return doc
    }

    // MARK: Rendering

    public static func render(page: CGPDFPage, dpi: Double) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = dpi / 72
        let pw = Int((size.width * scale).rounded(.up)), ph = Int((size.height * scale).rounded(.up))
        guard pw > 0, ph > 0, pw * ph < 300_000_000,
              let ctx = ImageKit.makeContext(width: pw, height: ph, opaque: true) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    public static func toImages(_ item: InputItem, format: ImageFormat, ctx: JobContext) async throws {
        guard let doc = CGPDFDocument(item.url as CFURL) else { throw TangeloError.unsupported("Couldn't open PDF.") }
        if doc.isEncrypted && !doc.unlockWithPassword("") { throw TangeloError.failed("This PDF is password-protected.") }
        let count = doc.numberOfPages
        guard count > 0 else { throw TangeloError.failed("This PDF has no pages.") }
        let dpi = ctx.settings.pdfDPI
        func write(_ page: CGPDFPage, to url: URL) throws {
            guard let img = render(page: page, dpi: dpi) else { throw TangeloError.failed("Couldn't render page.") }
            var settings = ctx.settings
            settings.keepLocation = false
            let props: [String: Any] = [kCGImagePropertyDPIWidth as String: dpi, kCGImagePropertyDPIHeight as String: dpi]
            if format == .webp {
                try WebP.write(img, to: url, quality: ctx.settings.quality, lossless: false, settings: settings)
            } else {
                try ImageKit.write(img, to: url, format: format, quality: ctx.settings.quality, properties: props, settings: settings)
            }
        }
        if count == 1, let page = doc.page(at: 1) {
            try await ctx.produce(ctx.destination(for: item.url, ext: format.ext)) { try write(page, to: $0) }
            return
        }
        let folder = try ctx.makeFolder(near: item.url, name: "\(item.baseName) (\(format.title))")
        let digits = String(count).count
        for i in 1...count {
            try ctx.check()
            ctx.report(Double(i - 1) / Double(count), "Page \(i) of \(count)")
            guard let page = doc.page(at: i) else { continue }
            let num = String(repeating: "0", count: max(0, digits - String(i).count)) + String(i)
            try write(page, to: folder.appendingPathComponent("\(item.baseName) - Page \(num).\(format.ext)"))
        }
    }

    // MARK: Text

    public static func text(of doc: PDFDocument) -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount { pages.append(doc.page(at: i)?.string ?? "") }
        return pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text via OCR for scanned PDFs.
    public static func ocrText(_ item: InputItem, ctx: JobContext) throws -> String {
        guard let doc = CGPDFDocument(item.url as CFURL) else { return "" }
        var out: [String] = []
        for i in 1...max(doc.numberOfPages, 1) {
            try ctx.check()
            ctx.report(Double(i - 1) / Double(doc.numberOfPages), "Reading page \(i) of \(doc.numberOfPages)")
            guard let page = doc.page(at: i), let img = render(page: page, dpi: 200) else { continue }
            out.append(try VisionKit.recognizeText(in: img))
        }
        return out.joined(separator: "\n\n")
    }

    public static func extractText(_ item: InputItem, ctx: JobContext) throws -> String {
        let doc = try open(item)
        let t = text(of: doc)
        if t.count > 20 { return t }
        return try ocrText(item, ctx: ctx)
    }

    public static func toText(_ item: InputItem, ctx: JobContext) async throws {
        let t = try extractText(item, ctx: ctx)
        guard !t.isEmpty else { throw TangeloError.failed("No text found in this PDF.") }
        try await ctx.produce(ctx.destination(for: item.url, ext: "txt")) { try t.write(to: $0, atomically: false, encoding: .utf8) }
    }

    /// PDF → DOCX / RTF / HTML / ODT / MD, keeping fonts and joining wrapped lines into paragraphs.
    public static func toDocument(_ item: InputItem, format: DocFormat, ctx: JobContext) async throws {
        let doc = try open(item)
        let attr = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            try ctx.check()
            if let s = doc.page(at: i)?.attributedString {
                attr.append(s)
                if i < doc.pageCount - 1 { attr.append(NSAttributedString(string: "\n\n")) }
            }
        }
        if attr.string.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            let t = try ocrText(item, ctx: ctx)
            guard !t.isEmpty else { throw TangeloError.failed("No text found in this PDF.") }
            attr.setAttributedString(DocActions.plainAttributed(t))
        } else {
            reflow(attr)
            normalizeFonts(attr)
        }
        try await DocActions.write(attr, like: item, format: format, ctx: ctx)
    }

    /// Embedded system fonts (".SFNS…") can't be referenced by other apps; map them to Helvetica Neue.
    static func normalizeFonts(_ attr: NSMutableAttributedString) {
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            guard let f = value as? NSFont, f.fontName.hasPrefix(".") else { return }
            let traits = f.fontDescriptor.symbolicTraits
            var replacement = NSFont(name: "HelveticaNeue", size: f.pointSize) ?? NSFont.systemFont(ofSize: f.pointSize)
            let manager = NSFontManager.shared
            if traits.contains(.bold) { replacement = manager.convert(replacement, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { replacement = manager.convert(replacement, toHaveTrait: .italicFontMask) }
            attr.addAttribute(.font, value: replacement, range: range)
        }
    }

    /// Joins lines that were wrapped by the PDF layout back into paragraphs.
    static func reflow(_ attr: NSMutableAttributedString) {
        let ns = attr.string as NSString
        var i = ns.length - 2
        while i > 0 {
            // A newline between "…word" and "lowercase…" is a soft wrap, not a paragraph break.
            if ns.character(at: i) == 10 {
                let prev = ns.character(at: i - 1)
                let sentenceEnd = [46, 33, 63, 58, 10].contains(prev) // . ! ? : \n
                if !sentenceEnd, let next = UnicodeScalar(ns.character(at: i + 1)), Character(next).isLowercase {
                    attr.replaceCharacters(in: NSRange(location: i, length: 1), with: " ")
                }
            }
            i -= 1
        }
    }

    // MARK: Page tools

    public static func merge(_ items: [InputItem], ctx: JobContext) async throws {
        guard let first = items.first else { return }
        if items.contains(where: { $0.kind != .pdf }) {
            try await ImageActions.combineToPDF(items, ctx: ctx)
            return
        }
        let out = PDFDocument()
        for item in items {
            try ctx.check()
            let doc = try open(item)
            for p in 0..<doc.pageCount {
                if let page = doc.page(at: p)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
            }
        }
        let dest = ctx.destination(named: first.baseName + " Merged", ext: "pdf", near: first.url)
        try await ctx.produce(dest) { tmp in
            guard out.write(to: tmp) else { throw TangeloError.failed("Couldn't write the merged PDF.") }
        }
    }

    public static func split(_ item: InputItem, ctx: JobContext) async throws {
        let doc = try open(item)
        guard doc.pageCount > 1 else { throw TangeloError.failed("This PDF has only one page.") }
        let folder = try ctx.makeFolder(near: item.url, name: "\(item.baseName) (Pages)")
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            try ctx.check()
            ctx.report(Double(i) / Double(doc.pageCount), "Page \(i + 1) of \(doc.pageCount)")
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            single.write(to: folder.appendingPathComponent("\(item.baseName) - Page \(num).pdf"))
        }
    }

    public static func rotate(_ item: InputItem, quarterTurns: Int, ctx: JobContext) async throws {
        let doc = try open(item)
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i) { p.rotation = ((p.rotation + quarterTurns * 90) % 360 + 360) % 360 }
        }
        try await ctx.produce(ctx.destination(for: item.url, ext: "pdf", suffix: "Rotated")) { tmp in
            guard doc.write(to: tmp) else { throw TangeloError.failed("Couldn't write PDF.") }
        }
    }

    public static func compress(_ item: InputItem, level: CompressLevel, ctx: JobContext) async throws {
        let doc = try open(item)
        let dest = ctx.destination(for: item.url, ext: "pdf", suffix: "Compressed")
        let out = try await ctx.produce(dest) { tmp in
            if level == .strong, let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) {
                try filtered(item.url, to: tmp, filter: filter)
                if ByteFormat.size(of: tmp) < (item.size > 0 ? item.size : ByteFormat.size(of: item.url)) { return }
            }
            var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if level != .light { opts[.optimizeImagesForScreenOption] = true }
            guard doc.write(to: tmp, withOptions: opts) else { throw TangeloError.failed("Couldn't write PDF.") }
        }
        try ImageActions.reportSavings(original: item, output: out, ctx: ctx)
    }

    static func filtered(_ src: URL, to dst: URL, filter: QuartzFilter) throws {
        guard let doc = CGPDFDocument(src as CFURL), let consumer = CGDataConsumer(url: dst as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw TangeloError.failed("Couldn't read PDF.") }
        _ = filter.apply(to: pdf)
        for i in 1...max(doc.numberOfPages, 1) {
            guard let page = doc.page(at: i) else { continue }
            var box = page.getBoxRect(.mediaBox)
            var info: [String: Any] = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            var crop = page.getBoxRect(.cropBox)
            info[kCGPDFContextCropBox as String] = Data(bytes: &crop, count: MemoryLayout<CGRect>.size)
            pdf.beginPDFPage(info as CFDictionary)
            pdf.drawPDFPage(page)
            pdf.endPDFPage()
        }
        filter.remove(from: pdf)
        pdf.closePDF()
    }

    /// Adds an invisible OCR text layer so scanned PDFs become searchable and selectable.
    public static func makeSearchable(_ item: InputItem, ctx: JobContext) async throws {
        let doc = try open(item)
        if text(of: doc).count > 50 { throw TangeloError.failed("This PDF already has selectable text.") }
        try await ctx.produce(ctx.destination(for: item.url, ext: "pdf", suffix: "Searchable")) { tmp in
            guard let cg = CGPDFDocument(item.url as CFURL), let consumer = CGDataConsumer(url: tmp as CFURL),
                  let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw TangeloError.failed("Couldn't read PDF.") }
            let n = cg.numberOfPages
            for i in 1...max(n, 1) {
                try ctx.check()
                ctx.report(Double(i - 1) / Double(n), "Reading page \(i) of \(n)")
                guard let page = cg.page(at: i) else { continue }
                let box = page.getBoxRect(.cropBox)
                let rotated = page.rotationAngle % 180 != 0
                var media = CGRect(origin: .zero, size: rotated ? CGSize(width: box.height, height: box.width) : box.size)
                let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
                pdf.beginPDFPage(info)
                pdf.saveGState()
                pdf.concatenate(page.getDrawingTransform(.cropBox, rect: media, rotate: 0, preserveAspectRatio: true))
                pdf.clip(to: box)
                pdf.drawPDFPage(page)
                pdf.restoreGState()
                let dpi = 200.0
                if let img = render(page: page, dpi: dpi) {
                    let lines = (try? VisionKit.recognizeLines(in: img)) ?? []
                    let s = 72 / dpi
                    pdf.setTextDrawingMode(.invisible)
                    for line in lines {
                        let r = CGRect(x: line.rect.minX * s, y: media.height - line.rect.maxY * s,
                                       width: line.rect.width * s, height: line.rect.height * s)
                        drawInvisible(line.text, in: r, ctx: pdf)
                    }
                }
                pdf.endPDFPage()
            }
            pdf.closePDF()
        }
    }

    static func drawInvisible(_ text: String, in rect: CGRect, ctx: CGContext) {
        let fontSize = max(rect.height * 0.85, 1)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.15)
        if width > 0 { ctx.scaleBy(x: rect.width / width, y: 1) }
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    public static func protect(_ item: InputItem, password: String, ctx: JobContext) async throws {
        let doc = try open(item)
        try await ctx.produce(ctx.destination(for: item.url, ext: "pdf", suffix: "Protected")) { tmp in
            guard doc.write(to: tmp, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
                throw TangeloError.failed("Couldn't write the protected PDF.")
            }
        }
    }

    public static func unlock(_ item: InputItem, password: String, ctx: JobContext) async throws {
        guard let doc = PDFDocument(url: item.url) else { throw TangeloError.unsupported("Couldn't open PDF.") }
        guard doc.isEncrypted else { throw TangeloError.failed("This PDF isn't password-protected.") }
        guard doc.unlock(withPassword: password) else { throw TangeloError.failed("Wrong password.") }
        let out = PDFDocument()
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
        }
        try await ctx.produce(ctx.destination(for: item.url, ext: "pdf", suffix: "Unlocked")) { tmp in
            guard out.write(to: tmp) else { throw TangeloError.failed("Couldn't write PDF.") }
        }
    }

    public static func isEncrypted(_ url: URL) -> Bool {
        PDFDocument(url: url)?.isEncrypted ?? false
    }
}
