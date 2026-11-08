import Foundation

// Reading a RIS or BibTeX export, which is what EndNote, Mendeley, Papers, Citavi and the rest all
// write. Such a file has no "date added", so the order that matters (what the user filed most
// recently) is recovered from successive imports: an item that was not in the last one is new.

/// An import as it is kept on the device: the items, and when each first appeared.
struct LibraryFile: Codable, Equatable {
    var name: String
    /// ISO 8601: when this file was last imported.
    var importedAt: String
    var items: [LibraryItem]
}

enum LibraryImport {
    enum Format: String { case ris, bibtex }

    // MARK: Reading a file

    /// The text of an export. Managers write UTF-8 (sometimes with a byte-order mark), UTF-16, or the
    /// Windows code page; a file that is none of those is not read rather than read wrongly.
    static func text(of data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return String(data: Data(body), encoding: .utf8) ?? String(data: Data(body), encoding: .windowsCP1252)
    }

    /// What the text is, from what it holds before what the file is called: a `.txt` or no extension is common.
    static func format(of text: String, filename: String = "") -> Format? {
        let head = String(text.prefix(4000))
        if head.range(of: #"(?m)^\s*TY\s{1,2}-"#, options: .regularExpression) != nil { return .ris }
        if head.range(of: #"(?m)^\s*@\w+\s*[\{\(]"#, options: .regularExpression) != nil { return .bibtex }
        switch (filename as NSString).pathExtension.lowercased() {
        case "ris", "enw": return .ris
        case "bib", "bibtex": return .bibtex
        default: return nil
        }
    }

    static func items(from data: Data, filename: String = "") -> [LibraryItem] {
        guard let text = text(of: data), let format = format(of: text, filename: filename) else { return [] }
        return format == .ris ? ris(text) : bibtex(text)
    }

    // MARK: RIS

    /// Records run from `TY` to `ER`. A line that starts no tag continues the one before it, which is
    /// how EndNote wraps a long abstract.
    static func ris(_ text: String) -> [LibraryItem] {
        var out: [LibraryItem] = []
        var fields: [(tag: String, value: String)] = []
        var open = false

        func finish() {
            defer { fields = []; open = false }
            guard open else { return }
            func first(_ tags: [String]) -> String? {
                for t in tags { if let v = fields.first(where: { $0.tag == t })?.value, !v.isEmpty { return v } }
                return nil
            }
            guard let title = first(["TI", "T1"]) else { return }
            let abstract = fields.filter { $0.tag == "AB" || $0.tag == "N2" }.map(\.value).max { $0.count < $1.count }
            let tags = fields.filter { $0.tag == "KW" }.flatMap { split(keywords: $0.value) }
            out.append(LibraryItem(key: "", title: title, abstract: abstract.flatMap { $0.isEmpty ? nil : $0 },
                                   doi: Identifiers.doi(first(["DO"])), dateAdded: "", tags: tags,
                                   journal: first(["T2", "JO", "JF", "JA"]),
                                   itemType: (first(["TY"]) ?? "JOUR").lowercased(),
                                   published: first(["PY", "Y1", "DA"]).flatMap(year)))
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let m = line.range(of: #"^([A-Z][A-Z0-9])\s{1,2}-\s?"#, options: .regularExpression) {
                let tag = String(line[line.startIndex..<line.index(line.startIndex, offsetBy: 2)])
                let value = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
                if tag == "TY" { finish(); open = true }
                if tag == "ER" { finish(); continue }
                if open { fields.append((tag, value)) }
            } else if open, !fields.isEmpty {
                fields[fields.count - 1].value += " " + line
            }
        }
        finish()
        return out
    }

    // MARK: BibTeX

    /// Entries are `@type{key, field = {value}, field = "value", year = 2024}`. Braces nest; `@comment`,
    /// `@string` and `@preamble` hold no paper. A `date-added`, `dateadded` or `creationdate` field,
    /// which BibDesk, Mendeley and JabRef write, gives the date added.
    static func bibtex(_ text: String) -> [LibraryItem] {
        let c = Array(text)
        var i = 0
        var out: [LibraryItem] = []

        func skipSpace() { while i < c.count, c[i].isWhitespace { i += 1 } }
        func balanced(open: Character, close: Character) -> String {
            // At `open`; returns what is inside, leaving i after the matching close.
            var depth = 0, start = i + 1
            while i < c.count {
                if c[i] == "\\" { i += 2; continue }
                if c[i] == open { depth += 1 } else if c[i] == close { depth -= 1; if depth == 0 { break } }
                i += 1
            }
            let end = min(i, c.count)
            i = min(i + 1, c.count)
            return start <= end ? String(c[start..<end]) : ""
        }

        while i < c.count {
            guard c[i] == "@" else { i += 1; continue }
            i += 1
            var type = ""
            while i < c.count, c[i].isLetter { type.append(c[i]); i += 1 }
            skipSpace()
            guard i < c.count, c[i] == "{" || c[i] == "(" else { continue }
            let (open, close): (Character, Character) = c[i] == "{" ? ("{", "}") : ("(", ")")
            if ["comment", "string", "preamble"].contains(type.lowercased()) { _ = balanced(open: open, close: close); continue }
            let body = Array(balanced(open: open, close: close))
            if let item = entry(type: type.lowercased(), body: body) { out.append(item) }
        }
        return out
    }

    private static func entry(type: String, body: [Character]) -> LibraryItem? {
        var i = 0
        func skipSpace() { while i < body.count, body[i].isWhitespace { i += 1 } }
        while i < body.count, body[i] != "," { i += 1 }   // the citation key
        i += 1
        var fields: [String: String] = [:]
        while i < body.count {
            skipSpace()
            var name = ""
            while i < body.count, body[i] != "=", body[i] != "," { name.append(body[i]); i += 1 }
            guard i < body.count, body[i] == "=" else { i += 1; continue }
            i += 1
            skipSpace()
            var value = ""
            // A value is one piece or several joined by #.
            while i < body.count {
                skipSpace()
                guard i < body.count else { break }
                if body[i] == "{" || body[i] == "\"" {
                    let open = body[i], close: Character = open == "{" ? "}" : "\""
                    var depth = 0, start = i + 1
                    while i < body.count {
                        if body[i] == "\\" { i += 2; continue }
                        if open == "{" {
                            if body[i] == "{" { depth += 1 } else if body[i] == "}" { depth -= 1; if depth == 0 { break } }
                        } else if i > start - 1, body[i] == close, i != start - 1 { break }
                        i += 1
                    }
                    value += String(body[start..<min(i, body.count)])
                    i += 1
                } else {
                    var bare = ""
                    while i < body.count, body[i] != ",", body[i] != "#", !body[i].isWhitespace { bare.append(body[i]); i += 1 }
                    value += bare
                }
                skipSpace()
                if i < body.count, body[i] == "#" { i += 1; continue }
                break
            }
            fields[name.trimmingCharacters(in: .whitespaces).lowercased()] = value
            while i < body.count, body[i] != "," { i += 1 }
            i += 1
        }
        func get(_ names: [String]) -> String? {
            for n in names { if let v = fields[n].map(clean), !v.isEmpty { return v } }
            return nil
        }
        guard let title = get(["title"]) else { return nil }
        let added = get(["date-added", "dateadded", "creationdate", "timestamp"]).flatMap(isoDate)
        return LibraryItem(key: "", title: title, abstract: get(["abstract"]), doi: Identifiers.doi(get(["doi"])),
                           dateAdded: added ?? "", tags: get(["keywords", "keyword"]).map(split(keywords:)) ?? [],
                           journal: get(["journal", "journaltitle", "booktitle", "publisher"]),
                           itemType: type, published: get(["year", "date"]).flatMap(year))
    }

    private static let accents: [Character: String] = [
        "\"": "\u{308}", "'": "\u{301}", "`": "\u{300}", "^": "\u{302}", "~": "\u{303}", "=": "\u{304}",
        ".": "\u{307}", "c": "\u{327}", "v": "\u{30C}", "u": "\u{306}", "H": "\u{30B}", "k": "\u{328}",
    ]
    private static let specials: [(String, String)] = [
        (#"\ss"#, "ß"), (#"\ae"#, "æ"), (#"\AE"#, "Æ"), (#"\oe"#, "œ"), (#"\OE"#, "Œ"), (#"\aa"#, "å"),
        (#"\AA"#, "Å"), (#"\o"#, "ø"), (#"\O"#, "Ø"), (#"\l"#, "ł"), (#"\L"#, "Ł"), (#"\i"#, "ı"),
        (#"\&"#, "&"), (#"\%"#, "%"), (#"\_"#, "_"), (#"\$"#, "$"), ("\\#", "#"), (#"\textendash"#, "–"), (#"\textemdash"#, "—"),
    ]

    /// A BibTeX value as plain text: accents and a few symbols turned into their characters, the braces
    /// that protect capitals removed, white space made single.
    static func clean(_ raw: String) -> String {
        var s = raw
        // \"u, \"{u}, {\"u}, \c{c}, \v s …
        if let re = try? NSRegularExpression(pattern: #"\\(["'`^~=.cvuHk])\s*\{?\s*([A-Za-z])\s*\}?"#) {
            let ns = s as NSString
            var out = "", last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let mark = accents[Character(ns.substring(with: m.range(at: 1)))] ?? ""
                out += (ns.substring(with: m.range(at: 2)) + mark).precomposedStringWithCanonicalMapping
                last = m.range.location + m.range.length
            }
            s = out + ns.substring(from: last)
        }
        for (latex, plain) in specials.sorted(by: { $0.0.count > $1.0.count }) {
            // A command is not a prefix of a longer one: \o must not eat the start of \oe.
            s = s.replacingOccurrences(of: latex + "{}", with: plain).replacingOccurrences(of: latex, with: plain)
        }
        s = s.replacingOccurrences(of: #"\\[A-Za-z]+\*?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Shared small things

    static func split(keywords: String) -> [String] {
        keywords.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The four-digit year in "2024", "2024/05/01/", "May 2024" or "2024-05-01".
    static func year(_ text: String) -> String? {
        text.range(of: #"(?<!\d)(19|20)\d{2}(?!\d)"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// "2026-11-02 10:00:00 +0100" or "2026-11-02" as ISO 8601, for a date the file does give.
    static func isoDate(_ text: String) -> String? {
        guard let m = text.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return String(text[m]) + "T00:00:00Z"
    }

    // MARK: Rough pastes

    /// Whatever the user pasted: a RIS or BibTeX export if it is one, else a list of references or
    /// of titles, as copied from a manager's list, a bibliography or a paper's reference section.
    /// Entries are told apart by blank lines, or by lines when there are none. An entry gives a
    /// title (the part after the year in "Author A, Author B (2024). Title. Journal.", a quoted
    /// title, or the whole line) and a DOI if one is in it. An entry with nothing to compare, such as a
    /// bare DOI, is left out: it says nothing about what the paper is about.
    static func rough(_ text: String) -> [LibraryItem] {
        if let format = format(of: text) { return format == .ris ? ris(text) : bibtex(text) }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var blocks: [String] = []
        var current: [String] = []
        for l in lines + [""] {
            if l.isEmpty { if !current.isEmpty { blocks.append(current.joined(separator: " ")); current = [] } }
            else { current.append(l) }
        }
        // No blank lines at all: every line is an entry.
        if blocks.count == 1, lines.filter({ !$0.isEmpty }).count > 1 {
            blocks = lines.filter { !$0.isEmpty }
        }
        return blocks.compactMap(roughEntry)
    }

    private static func roughEntry(_ raw: String) -> LibraryItem? {
        var entry = raw.replacingOccurrences(of: #"^\s*(\[\d+\]|\d+[.)]|[-•*])\s+"#, with: "", options: .regularExpression)
        var doi: String?
        if let r = entry.range(of: #"10\.\d{4,9}/[^\s"<>]+"#, options: .regularExpression) {
            doi = Identifiers.doi(String(entry[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}")))
            entry.removeSubrange(r)
        }
        entry = entry.replacingOccurrences(of: #"(?i)\b(doi:?|https?://(dx\.)?doi\.org/?|https?://\S+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;")))
        var title: String?
        var journal: String?
        if let q = entry.range(of: #"[“"]([^”"]{15,})[”"]"#, options: .regularExpression) {
            title = String(entry[q]).trimmingCharacters(in: CharacterSet(charactersIn: "“”\" ,."))
        } else {
            func segments(_ t: String) -> [String] {
                t.components(separatedBy: ". ").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;"))) }.filter { !$0.isEmpty }
            }
            func venue(_ t: String?) -> String? {
                t.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",;")).first?.trimmingCharacters(in: .whitespaces) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            if let y = entry.range(of: #"\((19|20)\d{2}[a-z]?\)\.?\s+|\b(19|20)\d{2}[a-z]?\.\s+"#, options: .regularExpression) {
                // APA and its relatives: the title is what follows the year, then the journal.
                let parts = segments(String(entry[y.upperBound...]))
                if let first = parts.first, first.count >= 15 { title = first; journal = venue(parts.count > 1 ? parts[1] : nil) }
            } else {
                // Vancouver and its relatives: authors first ("Legrain V, Mouraux A."), then the title, then the journal.
                let parts = segments(entry)
                let authors = #"^([\p{L}'’\-]+( [\p{L}'’\-]+)? \p{Lu}{1,3}(, |$))+"#
                if parts.count >= 2, parts[0].range(of: authors, options: .regularExpression) != nil, parts[1].count >= 15 {
                    title = parts[1]; journal = venue(parts.count > 2 ? parts[2] : nil)
                }
            }
        }
        if title == nil, entry.count >= 15 { title = entry }
        guard let title else { return nil }
        return LibraryItem(key: "", title: title, abstract: nil, doi: doi, dateAdded: "", tags: [], journal: journal,
                           itemType: "pasted", published: year(raw))
    }

    // MARK: Keeping an import

    /// The key that says two entries are one paper: the DOI, else the title with its punctuation gone.
    static func key(_ i: LibraryItem) -> String {
        if let doi = i.doi { return "doi:" + doi }
        return "title:" + i.title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// What to keep after importing `parsed` over `previous`. An item that was already there keeps the
    /// date it first appeared; one the file dates itself keeps that date; the rest are new today. A
    /// first import therefore dates everything alike, and the second one tells what was added since.
    static func merged(previous: LibraryFile?, parsed: [LibraryItem], name: String, now: Date,
                       limit: Int = 5000) -> LibraryFile {
        let stamp = ISO8601DateFormatter().string(from: now)
        let before = Dictionary((previous?.items ?? []).map { (key($0), $0.dateAdded) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var items: [LibraryItem] = []
        for var item in parsed {
            let k = key(item)
            guard seen.insert(k).inserted else { continue }
            item.key = k
            if let kept = before[k], !kept.isEmpty { item.dateAdded = kept }
            else if item.dateAdded.isEmpty { item.dateAdded = stamp }
            items.append(item)
        }
        return LibraryFile(name: name, importedAt: stamp, items: Array(items.prefix(limit)))
    }
}

extension LibraryImport {
    /// A paste added to what is held: the new items count as added now, the old ones keep their dates,
    /// and a paper pasted twice is one.
    static func adding(to previous: LibraryFile?, parsed: [LibraryItem], name: String, now: Date) -> LibraryFile {
        merged(previous: previous, parsed: parsed + (previous?.items ?? []), name: previous?.name ?? name, now: now)
    }
}
