import Foundation

/// CSV / TSV / JSON / XLSX conversions. The first row of a table is the header.
public enum DataActions {
    public typealias Table = [[String]]

    // MARK: Reading

    public static func readTable(_ item: InputItem) throws -> Table {
        switch item.format {
        case "csv":
            let text = try DocActions.readText(item.url)
            return parseDelimited(text, delimiter: sniffDelimiter(text))
        case "tsv": return parseDelimited(try DocActions.readText(item.url), delimiter: "\t")
        case "json": return try tableFromJSON(Data(contentsOf: item.url))
        case "xlsx": return try XLSX.read(item.url)
        default: throw TangeloError.unsupported("Not a data file.")
        }
    }

    static func sniffDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix(while: { $0 != "\n" })
        let counts: [(Character, Int)] = [(",", 0), (";", 0), ("\t", 0)].map { d in (d.0, firstLine.filter { $0 == d.0 }.count) }
        return counts.max { $0.1 < $1.1 }.map { $0.1 > 0 ? $0.0 : "," } ?? ","
    }

    /// RFC 4180 parser (quoted fields, escaped quotes, newlines inside quotes).
    public static func parseDelimited(_ text: String, delimiter: Character) -> Table {
        var rows: Table = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: inQuotes = true
            case delimiter: row.append(field); field = ""
            case "\r\n", "\n", "\r":
                row.append(field); field = ""
                rows.append(row); row = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        if let first = rows.first, first.first?.hasPrefix("\u{FEFF}") == true {
            rows[0][0] = String(first[0].dropFirst())
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    static func tableFromJSON(_ data: Data) throws -> Table {
        guard var json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw TangeloError.failed("This JSON file isn't valid.")
        }
        // {"items": [...]} → use the first array inside.
        if let obj = json as? [String: Any], let arr = obj.values.first(where: { $0 is [Any] }) { json = arr }
        if let obj = json as? [String: Any] { json = [obj] }
        guard let array = json as? [Any] else { throw TangeloError.failed("Expected a list of records in this JSON.") }
        if let rows = array as? [[Any]] { return rows.map { $0.map(cellString) } }
        // Ordered keys: keep first-seen order by scanning the raw text.
        var keys: [String] = []
        var seen = Set<String>()
        let objects = array.compactMap { $0 as? [String: Any] }
        let orderedKeys = keyOrder(in: data)
        for o in objects {
            for k in o.keys.sorted(by: { (orderedKeys[$0] ?? .max) < (orderedKeys[$1] ?? .max) }) where !seen.contains(k) {
                seen.insert(k); keys.append(k)
            }
        }
        guard !keys.isEmpty else { throw TangeloError.failed("No records found in this JSON.") }
        return [keys] + objects.map { o in keys.map { o[$0].map(cellString) ?? "" } }
    }

    static func keyOrder(in data: Data) -> [String: Int] {
        let text = String(decoding: data, as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"\s*:"#) else { return [:] }
        var order: [String: Int] = [:]
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text), order[String(text[r])] == nil { order[String(text[r])] = order.count }
        }
        return order
    }

    static func cellString(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case is NSNull: return ""
        default:
            if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                return String(decoding: d, as: UTF8.self)
            }
            return "\(v)"
        }
    }

    // MARK: Writing

    public static func csv(_ t: Table, delimiter: String = ",") -> String {
        t.map { row in
            row.map { f in
                f.contains(delimiter) || f.contains("\"") || f.contains("\n") || f.contains("\r")
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: delimiter)
        }.joined(separator: "\n") + "\n"
    }

    /// Plain numbers only: "42", "-3.5", "1e6" — not "007" or "1,000".
    static func isNumber(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }

    static func typed(_ s: String) -> Any {
        if s.isEmpty { return NSNull() }
        if s == "true" { return true }
        if s == "false" { return false }
        if isNumber(s) {
            if !s.contains("."), !s.lowercased().contains("e"), let i = Int(s) { return i }
            if let d = Double(s) { return d }
        }
        return s
    }

    public static func json(_ t: Table) throws -> Data {
        guard let header = t.first else { return Data("[]".utf8) }
        // Build JSON text manually so keys keep their column order.
        var out = "[\n"
        for (ri, row) in t.dropFirst().enumerated() {
            out += "  {"
            for (ci, key) in header.enumerated() {
                let value = ci < row.count ? typed(row[ci]) : NSNull()
                let v = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                let k = try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes])
                out += (ci == 0 ? "" : ", ") + String(decoding: k, as: UTF8.self) + ": " + String(decoding: v, as: UTF8.self)
            }
            out += "}" + (ri < t.count - 2 ? "," : "") + "\n"
        }
        return Data((out + "]\n").utf8)
    }

    public static func html(_ t: Table, title: String) -> String {
        let esc = Markdown.escape
        var h = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(esc(title))</title><style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 32px; color: #1f2328; }
        table { border-collapse: collapse; font-size: 13px; } th, td { border: 1px solid #d0d7de; padding: 6px 10px; text-align: left; }
        th { background: #f6f8fa; position: sticky; top: 0; } tr:nth-child(even) td { background: #fbfbfc; }
        </style></head><body><table>
        """
        if let header = t.first { h += "<thead><tr>" + header.map { "<th>\(esc($0))</th>" }.joined() + "</tr></thead>" }
        h += "<tbody>" + t.dropFirst().map { "<tr>" + $0.map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }.joined(separator: "\n") + "</tbody>"
        return h + "</table></body></html>\n"
    }

    public static func markdownTable(_ t: Table) -> String {
        guard let header = t.first else { return "" }
        func line(_ r: [String]) -> String {
            "| " + (0..<header.count).map { i in (i < r.count ? r[i] : "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
        }
        return ([line(header), "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"] + t.dropFirst().map(line)).joined(separator: "\n") + "\n"
    }

    // MARK: Actions

    /// target: csv, tsv, json, xlsx, html, md
    public static func convert(_ item: InputItem, to target: String, ctx: JobContext) async throws {
        let table = try readTable(item)
        guard !table.isEmpty else { throw TangeloError.failed("No rows found.") }
        let dest = ctx.destination(for: item.url, ext: target)
        try await ctx.produce(dest) { tmp in
            switch target {
            case "csv": try csv(table).write(to: tmp, atomically: false, encoding: .utf8)
            case "tsv": try csv(table, delimiter: "\t").write(to: tmp, atomically: false, encoding: .utf8)
            case "json": try json(table).write(to: tmp)
            case "xlsx": try await XLSX.write(table, to: tmp, ctx: ctx)
            case "html": try html(table, title: item.baseName).write(to: tmp, atomically: false, encoding: .utf8)
            case "md": try markdownTable(table).write(to: tmp, atomically: false, encoding: .utf8)
            default: throw TangeloError.unsupported("Unknown data format.")
            }
        }
        ctx.summary = "\(max(table.count - 1, 0)) rows × \(table.first?.count ?? 0) columns"
    }

    /// Re-indents (or minifies) JSON without reordering keys.
    public static func reformatJSON(_ item: InputItem, pretty: Bool, ctx: JobContext) async throws {
        let data = try Data(contentsOf: item.url)
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw TangeloError.failed("This JSON file isn't valid.")
        }
        let text = String(decoding: data, as: UTF8.self)
        var out = ""
        var indent = 0
        var inString = false, escaped = false
        let pad = { (n: Int) in String(repeating: "  ", count: n) }
        var prev: Character = " "
        for c in text {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                prev = c
                continue
            }
            if c.isWhitespace { continue }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{", "[":
                out.append(c)
                if pretty { indent += 1; out += "\n" + pad(indent) }
            case "}", "]":
                if pretty {
                    indent -= 1
                    if prev == "{" || prev == "[" {
                        // Collapse empty containers: "{\n  " → "{"
                        while out.last == " " || out.last == "\n" { out.removeLast() }
                    } else { out += "\n" + pad(indent) }
                }
                out.append(c)
            case ",": out.append(c); if pretty { out += "\n" + pad(indent) }
            case ":": out += pretty ? ": " : ":"
            default: out.append(c)
            }
            prev = c
        }
        let suffix = pretty ? "Pretty" : "Minified"
        try await ctx.produce(ctx.destination(for: item.url, ext: "json", suffix: suffix)) { tmp in
            try (out + (pretty ? "\n" : "")).write(to: tmp, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - XLSX

enum XLSX {
    static func columnName(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for c in ref.uppercased() {
            guard let a = c.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(n - 1, 0)
    }

    static func xmlEscape(_ s: String) -> String {
        var out = Markdown.escape(s).replacingOccurrences(of: "'", with: "&apos;")
        // Strip characters XML 1.0 forbids.
        out.unicodeScalars.removeAll { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" }
        return out
    }

    static func write(_ table: DataActions.Table, to url: URL, ctx: JobContext) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tangelo-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        for d in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ s: String) throws {
            try ("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + s)
                .write(to: root.appendingPathComponent(path), atomically: false, encoding: .utf8)
        }
        let ns = "http://schemas.openxmlformats.org"
        try put("[Content_Types].xml", """
        <Types xmlns="\(ns)/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """)
        try put("_rels/.rels", """
        <Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        try put("xl/workbook.xml", """
        <workbook xmlns="\(ns)/spreadsheetml/2006/main" xmlns:r="\(ns)/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        try put("xl/_rels/workbook.xml.rels", """
        <Relationships xmlns="\(ns)/package/2006/relationships"><Relationship Id="rId1" Type="\(ns)/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\(ns)/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)
        try put("xl/styles.xml", """
        <styleSheet xmlns="\(ns)/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """)
        var sheet = "<worksheet xmlns=\"\(ns)/spreadsheetml/2006/main\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        let columnCount = table.map(\.count).max() ?? 0
        var widths: [Int] = []
        for c in 0..<columnCount {
            var longest = 8
            for row in table.prefix(200) where c < row.count { longest = max(longest, row[c].count) }
            widths.append(min(60, longest + 2))
        }
        if !widths.isEmpty {
            var cols = "<cols>"
            for (i, w) in widths.enumerated() { cols += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>" }
            sheet += cols + "</cols>"
        }
        sheet += "<sheetData>"
        for (r, row) in table.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                let style = r == 0 ? " s=\"1\"" : ""
                if r > 0, DataActions.isNumber(value) {
                    sheet += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                } else {
                    let space = value.first?.isWhitespace == true || value.last?.isWhitespace == true ? " xml:space=\"preserve\"" : ""
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t\(space)>\(xmlEscape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        try put("xl/worksheets/sheet1.xml", sheet)
        try await ProcessRunner.checked("/usr/bin/zip", ["-X", "-q", "-r", "-nw", url.path, "[Content_Types].xml", "_rels", "xl"],
                                        currentDirectory: root, ctx: ctx)
    }

    static func read(_ url: URL) throws -> DataActions.Table {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tangelo-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        guard try ProcessRunner.runAndWait("/usr/bin/ditto", ["-x", "-k", url.path, root.path], inheritOutput: true) == 0 else {
            throw TangeloError.failed("Couldn't open this spreadsheet.")
        }

        var shared: [String] = []
        if let d = try? Data(contentsOf: root.appendingPathComponent("xl/sharedStrings.xml")) {
            let h = SharedStringsParser(); let xp = XMLParser(data: d); xp.delegate = h; xp.parse(); shared = h.strings
        }
        var dateStyles = Set<Int>()
        if let d = try? Data(contentsOf: root.appendingPathComponent("xl/styles.xml")) {
            let h = StylesParser(); let xp = XMLParser(data: d); xp.delegate = h; xp.parse(); dateStyles = h.dateStyleIndices
        }
        var sheetPath = "xl/worksheets/sheet1.xml"
        if let wb = try? Data(contentsOf: root.appendingPathComponent("xl/workbook.xml")),
           let rels = try? Data(contentsOf: root.appendingPathComponent("xl/_rels/workbook.xml.rels")) {
            let w = FirstSheetParser(); let xp = XMLParser(data: wb); xp.delegate = w; xp.parse()
            let r = RelsParser(); let xr = XMLParser(data: rels); xr.delegate = r; xr.parse()
            if let id = w.firstSheetRID, let target = r.targets[id] {
                sheetPath = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        guard let sheetData = try? Data(contentsOf: root.appendingPathComponent(sheetPath)) else {
            throw TangeloError.failed("This spreadsheet has no sheets.")
        }
        let s = SheetParser(shared: shared, dateStyles: dateStyles)
        let xp = XMLParser(data: sheetData); xp.delegate = s; xp.parse()
        let width = s.rows.map { $0.keys.max().map { $0 + 1 } ?? 0 }.max() ?? 0
        return s.rows.map { r in (0..<width).map { r[$0] ?? "" } }
    }

    final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = "", inT = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { current = "" } else if e == "t" { inT = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inT { current += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false } else if e == "si" { strings.append(current) }
        }
    }

    final class StylesParser: NSObject, XMLParserDelegate {
        var dateStyleIndices = Set<Int>()
        private var customDateFormats = Set<Int>()
        private var inCellXfs = false, xfIndex = 0
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if e == "numFmt", let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"]?.lowercased() {
                let stripped = code.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
                if stripped.contains("y") || stripped.contains("d") || (stripped.contains("m") && !stripped.contains("0")) { customDateFormats.insert(id) }
            } else if e == "cellXfs" {
                inCellXfs = true; xfIndex = 0
            } else if e == "xf", inCellXfs {
                if let id = a["numFmtId"].flatMap(Int.init), (14...22).contains(id) || customDateFormats.contains(id) { dateStyleIndices.insert(xfIndex) }
                xfIndex += 1
            }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "cellXfs" { inCellXfs = false }
        }
    }

    final class FirstSheetParser: NSObject, XMLParserDelegate {
        var firstSheetRID: String?
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if e == "sheet", firstSheetRID == nil { firstSheetRID = a["r:id"] ?? a.first(where: { $0.key.hasSuffix(":id") })?.value }
        }
    }

    final class RelsParser: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            if e == "Relationship", let id = a["Id"], let t = a["Target"] { targets[id] = t }
        }
    }

    final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String], dateStyles: Set<Int>
        var rows: [[Int: String]] = []
        private var row: [Int: String] = [:]
        private var col = 0, type = "", style = -1, text = "", collecting = false
        init(shared: [String], dateStyles: Set<Int>) { self.shared = shared; self.dateStyles = dateStyles }

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row":
                row = [:]
                if let r = a["r"].flatMap(Int.init) { while rows.count < r - 1 { rows.append([:]) } }
            case "c":
                col = a["r"].map(XLSX.columnIndex) ?? (row.keys.max().map { $0 + 1 } ?? 0)
                type = a["t"] ?? "n"; style = a["s"].flatMap(Int.init) ?? -1; text = ""
            case "v", "t": collecting = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if collecting { text += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "v", "t": collecting = false
            case "c":
                var value = text
                switch type {
                case "s": value = Int(text).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
                case "b": value = text == "1" ? "TRUE" : "FALSE"
                case "n" where dateStyles.contains(style):
                    if let serial = Double(text) {
                        let date = Date(timeIntervalSince1970: (serial - 25569) * 86400)
                        let f = DateFormatter()
                        f.timeZone = TimeZone(identifier: "UTC")
                        f.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
                        value = f.string(from: date)
                    }
                default: break
                }
                row[col] = value
            case "row": rows.append(row)
            default: break
            }
        }
    }
}
