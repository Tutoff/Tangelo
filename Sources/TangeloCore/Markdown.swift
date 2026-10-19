import Foundation

/// A compact GitHub-flavored Markdown → HTML converter
/// (headings, emphasis, links, images, lists, task lists, quotes, code, tables, rules).
public enum Markdown {
    public static func toHTMLDocument(_ md: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.55;
               color: #1f2328; max-width: 780px; margin: 40px auto; padding: 0 24px; }
        h1, h2 { border-bottom: 1px solid #d1d9e0; padding-bottom: .3em; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        code { font-family: Menlo, Monaco, monospace; font-size: 0.88em; background: #f2f3f5; padding: .15em .35em; border-radius: 5px; }
        pre { background: #f6f8fa; padding: 14px 16px; border-radius: 8px; overflow: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0; padding: 0 1em; color: #59636e; border-left: .25em solid #d1d9e0; }
        table { border-collapse: collapse; margin: 1em 0; } th, td { border: 1px solid #d1d9e0; padding: 6px 13px; }
        th { background: #f6f8fa; } img { max-width: 100%; } hr { border: 0; border-top: 1px solid #d1d9e0; margin: 24px 0; }
        a { color: #0969da; }
        </style></head><body>
        \(toHTML(md))
        </body></html>
        """
    }

    public static func toHTML(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return blocks(lines[...])
    }

    // MARK: Blocks

    static func blocks(_ input: ArraySlice<String>) -> String {
        var out: [String] = []
        let lines = Array(input)
        var i = 0
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            // Indented code
            if line.hasPrefix("    ") {
                var code: [String] = []
                while i < lines.count && (lines[i].hasPrefix("    ") || isBlank(lines[i])) { code.append(String(lines[i].dropFirst(min(4, lines[i].count)))); i += 1 }
                while let last = code.last, last.trimmingCharacters(in: .whitespaces).isEmpty { code.removeLast() }
                out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                continue
            }
            // ATX heading
            if let h = heading(trimmed) { out.append(h); i += 1; continue }
            // Horizontal rule
            if isRule(trimmed) { out.append("<hr>"); i += 1; continue }
            // Blockquote
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.hasPrefix(" ") { q = q.dropFirst() }
                    quote.append(String(q)); i += 1
                }
                out.append("<blockquote>\n\(blocks(quote[...]))\n</blockquote>")
                continue
            }
            // Table
            if i + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[i + 1]) {
                var rows: [String] = [line]
                let sep = lines[i + 1]
                i += 2
                while i < lines.count, lines[i].contains("|"), !isBlank(lines[i]) { rows.append(lines[i]); i += 1 }
                out.append(table(header: rows[0], separator: sep, rows: Array(rows.dropFirst())))
                continue
            }
            // Lists
            if listMarker(line) != nil {
                let (html, consumed) = list(lines, from: i)
                out.append(html)
                i += consumed
                continue
            }
            // Raw HTML block
            if trimmed.hasPrefix("<") && !trimmed.hasPrefix("<http") {
                var raw: [String] = []
                while i < lines.count && !isBlank(lines[i]) { raw.append(lines[i]); i += 1 }
                out.append(raw.joined(separator: "\n"))
                continue
            }
            // Paragraph (with setext headings)
            var para: [String] = []
            while i < lines.count {
                let l = lines[i], t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || heading(t) != nil || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") { break }
                if !para.isEmpty && (listMarker(l) != nil || isRule(t) && !t.allSatisfy({ $0 == "-" })) { break }
                if !para.isEmpty, t.allSatisfy({ $0 == "=" }) {
                    out.append("<h1>\(inline(para.joined(separator: " ")))</h1>"); para = []; i += 1; break
                }
                if !para.isEmpty, t.count >= 2, t.allSatisfy({ $0 == "-" }) {
                    out.append("<h2>\(inline(para.joined(separator: " ")))</h2>"); para = []; i += 1; break
                }
                para.append(l); i += 1
            }
            if !para.isEmpty {
                let html = para.enumerated().map { idx, l -> String in
                    let hard = l.hasSuffix("  ") && idx < para.count - 1
                    return inline(l.trimmingCharacters(in: .whitespaces)) + (hard ? "<br>" : "")
                }.joined(separator: "\n")
                out.append("<p>\(html)</p>")
            }
        }
        return out.joined(separator: "\n")
    }

    static func heading(_ t: String) -> String? {
        guard t.hasPrefix("#") else { return nil }
        let level = t.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        text = text.trimmingCharacters(in: .whitespaces)
        return "<h\(level)>\(inline(text))</h\(level)>"
    }

    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    static func isTableSeparator(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func table(header: String, separator: String, rows: [String]) -> String {
        let aligns = cells(separator).map { c -> String in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return l && r ? " style=\"text-align:center\"" : r ? " style=\"text-align:right\"" : ""
        }
        func row(_ cs: [String], tag: String) -> String {
            "<tr>" + cs.enumerated().map { "<\(tag)\($0 < aligns.count ? aligns[$0] : "")>\(inline($1))</\(tag)>" }.joined() + "</tr>"
        }
        return "<table>\n<thead>\(row(cells(header), tag: "th"))</thead>\n<tbody>\n"
            + rows.map { row(cells($0), tag: "td") }.joined(separator: "\n") + "\n</tbody>\n</table>"
    }

    /// (indent, ordered, content) for a list item line.
    static func listMarker(_ line: String) -> (Int, Bool, String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        let t = line.dropFirst(indent)
        if let f = t.first, "-*+".contains(f), t.dropFirst().hasPrefix(" ") {
            if isRule(String(t)) { return nil }
            return (indent, false, String(t.dropFirst(2)))
        }
        let digits = t.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count < 10 {
            let after = t.dropFirst(digits.count)
            if (after.hasPrefix(". ") || after.hasPrefix(") ")) { return (indent, true, String(after.dropFirst(2))) }
        }
        return nil
    }

    static func list(_ lines: [String], from start: Int) -> (String, Int) {
        guard let (baseIndent, ordered, _) = listMarker(lines[start]) else { return ("", 1) }
        var items: [[String]] = []
        var i = start
        while i < lines.count {
            let l = lines[i]
            if let (ind, ord, content) = listMarker(l), ind <= baseIndent + 1, ord == ordered {
                items.append([content]); i += 1; continue
            }
            if l.trimmingCharacters(in: .whitespaces).isEmpty {
                // Continue the list only if the next non-blank line belongs to it.
                var j = i + 1
                while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, let (ind, _, _) = listMarker(lines[j]), ind >= baseIndent { i = j; continue }
                if j < lines.count, lines[j].prefix(while: { $0 == " " }).count > baseIndent + 1 { items[items.count - 1].append(""); i = j; continue }
                break
            }
            let ind = l.prefix(while: { $0 == " " }).count
            if ind > baseIndent, !items.isEmpty {
                items[items.count - 1].append(String(l.dropFirst(min(ind, baseIndent + 2)))); i += 1; continue
            }
            if listMarker(l) == nil, !items.isEmpty, ind <= baseIndent {
                // Lazy continuation of the item's paragraph.
                items[items.count - 1][items[items.count - 1].count - 1] += " " + l.trimmingCharacters(in: .whitespaces)
                i += 1; continue
            }
            break
        }
        let tag = ordered ? "ol" : "ul"
        let body = items.map { item -> String in
            var first = item[0]
            var checkbox = ""
            if first.hasPrefix("[ ] ") { checkbox = "<input type=\"checkbox\" disabled> "; first = String(first.dropFirst(4)) }
            else if first.lowercased().hasPrefix("[x] ") { checkbox = "<input type=\"checkbox\" checked disabled> "; first = String(first.dropFirst(4)) }
            if item.count == 1 { return "<li>\(checkbox)\(inline(first))</li>" }
            let nested = blocks(([first] + item.dropFirst())[...])
            // Unwrap the first paragraph so simple items stay tight.
            let inner = nested.hasPrefix("<p>") ? nested.replacingOccurrences(of: "<p>", with: "", options: .anchored)
                .replacingOccurrences(of: "</p>", with: "", options: [], range: nested.range(of: "</p>")) : nested
            return "<li>\(checkbox)\(inner)</li>"
        }.joined(separator: "\n")
        return ("<\(tag)>\n\(body)\n</\(tag)>", i - start)
    }

    // MARK: Inline

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inline(_ text: String) -> String {
        // Protect code spans first.
        var codes: [String] = []
        var s = ""
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|~<>".contains(chars[i + 1]) {
                codes.append(escape(String(chars[i + 1])))
                s += "\u{0}\(codes.count - 1)\u{0}"
                i += 2; continue
            }
            if chars[i] == "`" {
                let ticks = chars[i...].prefix(while: { $0 == "`" }).count
                let fence = String(repeating: "`", count: ticks)
                let rest = String(chars[(i + ticks)...])
                if let r = rest.range(of: fence) {
                    let code = String(rest[rest.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    codes.append("<code>\(escape(code))</code>")
                    s += "\u{0}\(codes.count - 1)\u{0}"
                    i += ticks + rest.distance(from: rest.startIndex, to: r.upperBound)
                    continue
                }
            }
            s.append(chars[i]); i += 1
        }
        chars = []

        var h = escape(s)
        func sub(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            h = re.stringByReplacingMatches(in: h, range: NSRange(h.startIndex..., in: h), withTemplate: template)
        }
        sub(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, "<img src=\"$2\" alt=\"$1\">")
        sub(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#, "<a href=\"$2\">$1</a>")
        sub(#"&lt;(https?://[^&\s]+)&gt;"#, "<a href=\"$1\">$1</a>")
        sub(#"\*\*\*(.+?)\*\*\*"#, "<strong><em>$1</em></strong>")
        sub(#"\*\*(.+?)\*\*"#, "<strong>$1</strong>")
        sub(#"(?<![\w])__(.+?)__(?![\w])"#, "<strong>$1</strong>")
        sub(#"\*(?!\s)(.+?)(?<!\s)\*"#, "<em>$1</em>")
        sub(#"(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])"#, "<em>$1</em>")
        sub(#"~~(.+?)~~"#, "<del>$1</del>")
        for (idx, code) in codes.enumerated() { h = h.replacingOccurrences(of: "\u{0}\(idx)\u{0}", with: code) }
        return h
    }
}
