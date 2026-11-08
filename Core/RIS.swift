import Foundation

// A paper as a reference-manager record. RIS is the one format every manager imports (Zotero,
// EndNote, Mendeley, Papers, Citavi, ReadCube), so a file is the way into all of them without an
// account, a key or a network call. Pure, so what gets written can be tested.

enum RIS {
    /// What a record is made from, whether it began as a post or as a saved or read paper.
    struct Reference: Equatable {
        var title: String
        var authors: [String] = []
        var journal: String? = nil
        /// yyyy-MM-dd
        var date: String
        var abstract: String? = nil
        var doi: String? = nil
        var pmid: String? = nil
        var url: String? = nil
        var keywords: [String] = []
        var language: String? = nil
        var isConference = false
    }

    static func reference(_ p: Paper) -> Reference {
        Reference(title: p.title, authors: p.authors, journal: p.journal, date: p.date, abstract: p.abstract,
                  doi: p.doi, pmid: p.pmid, url: p.link?.absoluteString, keywords: p.topics,
                  language: p.language, isConference: p.kind == .conferenceAbstract)
    }

    /// A saved or read paper holds an id, a title, an abstract, a date and (since later saves)
    /// authors and the journal. The DOI or PMID is the id. `known` is the full paper when the feed
    /// still holds it: it fills what an older entry lacks.
    static func reference(_ s: SavedPaper, known: Paper? = nil) -> Reference {
        var r = known.map(reference) ?? Reference(title: s.title, date: s.date)
        r.title = s.title
        r.abstract = s.abstract ?? r.abstract
        if r.authors.isEmpty { r.authors = s.authors ?? [] }
        r.journal = r.journal ?? s.journal
        if r.doi == nil, s.id.hasPrefix("doi:") { r.doi = String(s.id.dropFirst(4)) }
        if r.pmid == nil, s.id.hasPrefix("pmid:") { r.pmid = String(s.id.dropFirst(5)) }
        if r.url == nil { r.url = s.link?.absoluteString }
        return r
    }

    /// Saved or read papers as references, each filled from the feed's copy where the feed still
    /// holds one (matched by the key a saved paper is stored under).
    static func references(_ saved: [SavedPaper], known: [Paper]) -> [Reference] {
        let byKey = Dictionary(known.map { ($0.dedupeKey, $0) }, uniquingKeysWith: { first, _ in first })
        return saved.map { reference($0, known: byKey[$0.id]) }
    }

    /// The file, with one record per reference. RIS wants CRLF line ends and "TAG  - value".
    static func document(_ references: [Reference]) -> String {
        references.map(record).joined()
    }

    static func record(_ r: Reference) -> String {
        var lines: [(String, String)] = [("TY", r.isConference ? "CONF" : "JOUR")]
        for a in r.authors.map(author) where !a.isEmpty { lines.append(("AU", a)) }
        lines.append(("TI", r.title))
        if let journal = r.journal { lines.append(("T2", journal)) }
        if let year = year(r.date) { lines.append(("PY", year)) }
        if let da = ris(date: r.date) { lines.append(("DA", da)) }
        if let abstract = r.abstract { lines.append(("AB", abstract)) }
        if let doi = r.doi { lines.append(("DO", doi)) }
        if let pmid = r.pmid { lines.append(("AN", "PMID:" + pmid)) }
        if let url = r.url { lines.append(("UR", url)) }
        for k in r.keywords { lines.append(("KW", k)) }
        if let language = r.language { lines.append(("LA", language)) }
        lines.append(("ER", ""))
        return lines
            .map { tag, value in (tag, flat(value)) }
            .filter { tag, value in tag == "ER" || !value.isEmpty }
            .map { tag, value in tag == "ER" ? "ER  - \r\n" : "\(tag)  - \(value)\r\n" }
            .joined()
            + "\r\n"
    }

    /// A value is one line: a break inside it would start a new, malformed, tag.
    private static func flat(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let particles: Set<String> = [
        "van", "von", "de", "der", "den", "del", "della", "di", "da", "dos", "das", "du", "la", "le",
        "ten", "ter", "bin", "ibn", "al", "el", "st", "st.", "mac", "op",
    ]
    private static let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]

    /// "Last, First", which is what managers split on. Names arrive as "Valéry Legrain" (OpenAlex)
    /// or "Legrain V" (Europe PMC: surname, then initials); a name that already has a comma is kept.
    /// A particle stays with the surname ("Ludwig van der Berg" is "van der Berg, Ludwig"). It is a
    /// guess for names that follow no pattern, and a manager lets the user correct one.
    static func author(_ name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.contains(",") { return name }
        var words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 1 else { return name }
        var suffix = ""
        if let last = words.last, suffixes.contains(last.lowercased()), words.count > 2 {
            suffix = " " + last
            words.removeLast()
        }
        // "Legrain V", "Smith JA": initials last.
        if let last = words.last, last.count <= 3, last.allSatisfy({ $0.isUppercase && $0.isLetter }) {
            return words.dropLast().joined(separator: " ") + suffix + ", " + last
        }
        var start = words.count - 1
        while start > 1, particles.contains(words[start - 1].lowercased()) { start -= 1 }
        return words[start...].joined(separator: " ") + suffix + ", " + words[..<start].joined(separator: " ")
    }

    static func year(_ date: String) -> String? {
        let y = date.prefix(4)
        return y.count == 4 && y.allSatisfy(\.isNumber) ? String(y) : nil
    }

    /// "2026-10-03" as "2026/10/03/", the form RIS uses; a bare year is "2026///".
    static func ris(date: String) -> String? {
        guard let y = year(date) else { return nil }
        let parts = date.split(separator: "-").map(String.init)
        let m = parts.count > 1 && parts[1].count == 2 ? parts[1] : ""
        let d = parts.count > 2 && parts[2].count == 2 ? parts[2] : ""
        return "\(y)/\(m)/\(d)/"
    }

    /// "Legrain-2026-Cortical-gamma-responses.ris": who, when and what, so a file in Downloads is
    /// recognisable. Only letters and digits survive, because a file name goes through every app.
    static func fileName(for r: Reference) -> String {
        let surname = r.authors.first.map(author).map { $0.components(separatedBy: ",")[0] } ?? ""
        let words = r.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(4).map(String.init)
        let parts = [surname, year(r.date) ?? ""] + words
        let stem = parts.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } }.filter { !$0.isEmpty }.joined(separator: "-")
        return (stem.isEmpty ? "reference" : String(stem.prefix(80))) + ".ris"
    }
}
