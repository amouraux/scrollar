import Foundation

// Crossref: every DOI from every publisher, in every field, with no key. It is asked only when
// OpenAlex is off, as the keyless way outside biomedicine. What it can answer is narrow: a phrase in
// titles (its abstracts are present for about a third of the records and it has no abstract search), a
// journal by its name and an author by their name. It cannot list who cites a paper, an institution's
// papers or a funder's, so those stay with OpenAlex. Query building and reading are pure; the call is
// the last struct.

/// A name as typed or stored ("Mouraux A", "Ada Lovelace") against the names a source gives.
enum AuthorName {
    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    private static func words(_ s: String) -> [String] {
        fold(s).split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Every word of two letters or more in the query is a word of the author's name, and a single
    /// letter (an initial) begins the given name, or any word of it when the source gives one string.
    static func matches(_ query: String, given: String, family: String) -> Bool {
        let known = Set(words(given + " " + family))
        let initials = Set((given.isEmpty ? words(family) : words(given)).compactMap(\.first))
        let queryWords = words(query)
        guard !queryWords.isEmpty else { return false }
        return queryWords.allSatisfy { w in w.count >= 2 ? known.contains(w) : initials.contains(w.first!) }
    }
}

enum CrossrefQuery {
    static let fields = "DOI,title,abstract,container-title,author,published,created,is-referenced-by-count,link,license,type"

    /// The request parameters for one seed, or nil when Crossref cannot answer it.
    static func build(_ seed: Seed, since: String, until: String, rows: Int = 100, offset: Int = 0) -> [URLQueryItem]? {
        func name(_ id: String, _ display: String) -> String { SourceRouting.isNamed(id) ? String(id.dropFirst(5)) : display }
        var items: [URLQueryItem]
        switch seed {
        case .keyword(let k, let also):
            items = [URLQueryItem(name: "query.title", value: ([k] + also).joined(separator: " "))]
        case .journal(let id, let display):
            items = [URLQueryItem(name: "query.container-title", value: name(id, display))]
        case .author(let id, let display):
            items = [URLQueryItem(name: "query.author", value: name(id, display))]
        default:
            return nil
        }
        items += [
            URLQueryItem(name: "filter", value: "from-pub-date:\(since),until-pub-date:\(until),type:journal-article,type:posted-content"),
            URLQueryItem(name: "rows", value: String(rows)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "select", value: fields),
        ]
        return items
    }
}

enum CrossrefParser {
    static func total(in data: Data) -> Int {
        (((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? [String: Any])?["total-results"] as? Int) ?? 0
    }

    /// The papers in an answer that really are about the seed. Crossref ranks by loose likeness, so
    /// what it returns is checked: a phrase must be in the title or abstract, a journal's name must be
    /// the one asked for, an author's name must match one on the paper.
    static func papers(from data: Data, seed: Seed) -> [Paper] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["message"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap(paper).filter { accepts($0.paper, authors: $0.authors, seed: seed) }.map(\.paper)
    }

    private static func squash(_ s: String) -> String {
        AuthorName.fold(s).filter { $0.isLetter || $0.isNumber }
    }

    private static func accepts(_ p: Paper, authors: [(given: String, family: String)], seed: Seed) -> Bool {
        switch seed {
        case .keyword(let k, let also):
            let text = AuthorName.fold(p.title + " " + (p.abstract ?? ""))
            return ([k] + also).allSatisfy { text.contains(AuthorName.fold($0)) }
        case .journal(let id, let display):
            let wanted = SourceRouting.isNamed(id) ? String(id.dropFirst(5)) : display
            return p.journal.map { squash($0) == squash(wanted) } ?? false
        case .author(let id, let display):
            let wanted = SourceRouting.isNamed(id) ? String(id.dropFirst(5)) : display
            return authors.contains { AuthorName.matches(wanted, given: $0.given, family: $0.family) }
        default:
            return false
        }
    }

    /// Dates are often only a year and a month; the day DOI was registered is exact, and is used when
    /// it falls in the same month.
    static func date(_ record: [String: Any]) -> String? {
        func parts(_ key: String) -> [Int]? {
            (((record[key] as? [String: Any])?["date-parts"] as? [[Int?]])?.first)?.compactMap { $0 }
        }
        guard let published = parts("published"), let year = published.first else { return nil }
        func format(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        if published.count >= 3 { return format(year, published[1], published[2]) }
        let month = published.count >= 2 ? published[1] : 1
        if let created = parts("created"), created.count >= 3, created[0] == year, published.count < 2 || created[1] == month {
            return format(year, created[1], created[2])
        }
        return format(year, month, 1)
    }

    static func paper(_ r: [String: Any]) -> (paper: Paper, authors: [(given: String, family: String)])? {
        guard let doi = Identifiers.doi(r["DOI"] as? String),
              let rawTitle = (r["title"] as? [String])?.first else { return nil }
        let title = Html.plain(rawTitle)
        guard !title.isEmpty, let date = date(r) else { return nil }
        // JATS blocks (a heading, paragraphs) are separated by a space; inline marks (italic, sub) are not.
        var abstract = (r["abstract"] as? String).map {
            Html.plain($0.replacingOccurrences(of: #"</?jats:(title|p|sec|list|list-item|break)[^>]*>"#, with: " ", options: .regularExpression))
        }
        if let a = abstract, a.lowercased().hasPrefix("abstract ") { abstract = String(a.dropFirst(9)) }
        let preprint = (r["type"] as? String) == "posted-content"
        let authorRecords = (r["author"] as? [[String: Any]]) ?? []
        let people = authorRecords.map { (given: ($0["given"] as? String) ?? "", family: ($0["family"] as? String) ?? ($0["name"] as? String) ?? "") }
        let names = people.map { "\($0.given) \($0.family)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func institution(_ a: [String: Any]?) -> String? {
            ((a?["affiliation"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.compactMap(Affiliation.institution).first
        }
        // Open only where a Creative Commons licence says so; a publisher's own link is not a free PDF.
        let licences = ((r["license"] as? [[String: Any]]) ?? []).compactMap { $0["URL"] as? String }
        let open = licences.contains { $0.contains("creativecommons.org") }
        let pdf = open ? ((r["link"] as? [[String: Any]]) ?? []).first { ($0["content-type"] as? String) == "application/pdf" }?["URL"] as? String : nil
        let paper = Paper(
            id: "crossref:\(doi)",
            doi: doi,
            title: title,
            abstract: abstract.flatMap { $0.isEmpty ? nil : $0 },
            journal: (r["container-title"] as? [String])?.first,
            isRepository: preprint,
            openAlexType: preprint ? "preprint" : "article",
            sourceType: preprint ? "repository" : "journal",
            date: date,
            authors: names,
            firstInstitution: institution(authorRecords.first),
            lastInstitution: institution(authorRecords.last),
            citedBy: (r["is-referenced-by-count"] as? Int) ?? 0,
            isOpenAccess: open,
            pdfURL: pdf,
            sources: [SourceKind.crossref.rawValue]
        )
        return (paper, people)
    }
}
