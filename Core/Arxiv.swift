import Foundation

// arXiv: physics, mathematics, computer science, statistics and quantitative biology, the day a paper is
// posted (OpenAlex can be days behind) and with its abstract. No key. It answers a phrase in titles and
// abstracts, and an author's name. Its terms ask for no more than one request in three seconds, so every
// call waits its turn behind one shared gate. Thank you to arXiv for use of its open access
// interoperability.

/// Lets one request through every `interval` seconds, however many are waiting.
actor RequestGate {
    private var next = Date.distantPast
    let interval: TimeInterval

    init(interval: TimeInterval) { self.interval = interval }

    func wait() async {
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}

enum ArxivQuery {
    /// The request parameters for one seed, or nil when arXiv cannot answer it. `since` and `until` are
    /// yyyy-MM-dd, bounding the day the paper was first submitted.
    static func build(_ seed: Seed, since: String, until: String, start: Int = 0, count: Int = 100) -> [URLQueryItem]? {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: " ") + "\"" }
        let terms: String
        switch seed {
        case .keyword(let k, let also):
            terms = ([k] + also).map { "(ti:\(quote($0)) OR abs:\(quote($0)))" }.joined(separator: " AND ")
        case .author(let id, let display):
            let name = SourceRouting.isNamed(id) ? String(id.dropFirst(5)) : display
            // arXiv matches words of a name, not the form "Mouraux A": initials are left to the check afterwards.
            let words = AuthorName.fold(name).split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 2 }
            guard !words.isEmpty else { return nil }
            terms = words.map { "au:\($0)" }.joined(separator: " AND ")
        default:
            return nil
        }
        let range = "submittedDate:[\(since.replacingOccurrences(of: "-", with: ""))0000 TO \(until.replacingOccurrences(of: "-", with: ""))2359]"
        return [
            URLQueryItem(name: "search_query", value: "(\(terms)) AND \(range)"),
            URLQueryItem(name: "sortBy", value: "submittedDate"),
            URLQueryItem(name: "sortOrder", value: "descending"),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "max_results", value: String(count)),
        ]
    }
}

enum ArxivParser {
    private struct Entry {
        var id = "", title = "", summary = "", published = "", doi = ""
        var authors: [String] = []
        var affiliations: [String] = []
        var pdf = ""
    }

    /// Reads the Atom feed arXiv answers with. Only entries are read; a feed with none gives none.
    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var current: Entry?
        private var text = ""
        private var inAuthor = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "entry": current = Entry()
            case "author": inAuthor = true
            case "link":
                if current != nil, attributes["title"] == "pdf" || attributes["type"] == "application/pdf" {
                    current?.pdf = attributes["href"] ?? ""
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            switch name {
            case "entry":
                if let e = current { entries.append(e) }
                current = nil
            case "author": inAuthor = false
            case "id": if current != nil, current?.id.isEmpty == true { current?.id = value }
            case "title": if current != nil, current?.title.isEmpty == true { current?.title = value }
            case "summary": current?.summary = value
            case "published": current?.published = value
            case "name": if inAuthor, !value.isEmpty { current?.authors.append(value) }
            case "arxiv:affiliation": if !value.isEmpty { current?.affiliations.append(value) }
            case "arxiv:doi": current?.doi = value
            default: break
            }
            text = ""
        }
    }

    /// How many entries a feed holds, to know whether another page may exist.
    static func entryCount(in data: Data) -> Int {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        return parser.parse() ? reader.entries.count : 0
    }

    /// The papers in a feed that really are about the seed (an author's name is checked word by word,
    /// since arXiv matches words anywhere in the author list).
    static func papers(from data: Data, seed: Seed) -> [Paper] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return [] }
        return reader.entries.compactMap(paper).filter { p in
            guard case .author(let id, let display) = seed else { return true }
            let wanted = SourceRouting.isNamed(id) ? String(id.dropFirst(5)) : display
            return p.authors.contains { AuthorName.matches(wanted, given: "", family: $0) }
        }
    }

    /// "http://arxiv.org/abs/2611.09805v1" is 2611.09805; the version is not part of the paper.
    static func identifier(_ url: String) -> String? {
        guard let range = url.range(of: "/abs/") else { return nil }
        let id = String(url[range.upperBound...]).replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        return id.isEmpty ? nil : id
    }

    private static func paper(_ e: Entry) -> Paper? {
        guard let id = identifier(e.id), !e.title.isEmpty, e.published.count >= 10 else { return nil }
        let doi = Identifiers.doi(e.doi.isEmpty ? "10.48550/arXiv.\(id)" : e.doi)
        return Paper(
            id: "arxiv:\(id)",
            doi: doi,
            title: Html.plain(e.title),
            abstract: e.summary.isEmpty ? nil : e.summary,
            journal: "arXiv",
            isRepository: true,
            openAlexType: "preprint",
            sourceType: "repository",
            date: String(e.published.prefix(10)),
            authors: e.authors,
            firstInstitution: e.affiliations.first.flatMap(Affiliation.institution),
            isOpenAccess: true,
            pdfURL: "https://arxiv.org/pdf/\(id)",
            sources: [SourceKind.arXiv.rawValue]
        )
    }
}
