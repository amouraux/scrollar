import Foundation

// Foundation only, no networking: everything here is a pure function so the
// tests can run in a second without a network or a simulator.

enum Identifiers {
    /// "https://openalex.org/W123" -> "W123"
    static func openAlexID(_ s: String) -> String {
        s.split(separator: "/").last.map(String.init) ?? s
    }

    /// DOIs arrive as URLs in mixed case; two records of one paper only match
    /// once both are reduced to the bare lowercase form.
    static func doi(_ s: String?) -> String? {
        guard var d = s?.trimmingCharacters(in: .whitespaces).lowercased(), !d.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] where d.hasPrefix(prefix) {
            d.removeFirst(prefix.count)
        }
        return d
    }

    /// "https://pubmed.ncbi.nlm.nih.gov/12345" -> "12345"
    static func pmid(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.split(separator: "/").last.map(String.init)
    }
}

enum PDFLink {
    /// A link worth trying to show in the reader: https only (the system refuses plain http),
    /// and one that can be parsed. Anything else is no link.
    static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: s), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return s
    }

    /// OpenAlex: the best open-access location's PDF, else the one the paper is published at.
    static func openAlex(best: String?, primary: String?) -> String? { clean(best) ?? clean(primary) }

    /// Europe PMC `fullTextUrlList`: the first PDF it calls open access or free.
    static func europePMC(_ record: [String: Any]) -> String? {
        let list = ((record["fullTextUrlList"] as? [String: Any])?["fullTextUrl"] as? [[String: Any]]) ?? []
        let free: Set<String> = ["open access", "free"]
        return list
            .filter { ($0["documentStyle"] as? String)?.lowercased() == "pdf"
                      && free.contains(($0["availability"] as? String)?.lowercased() ?? "") }
            .compactMap { clean($0["url"] as? String) }
            .first
    }
}

struct Paper: Hashable, Codable {
    var id: String
    var doi: String? = nil
    var pmid: String? = nil
    var title: String
    var abstract: String? = nil
    var journal: String? = nil
    /// Repositories (Zenodo, a university library) are listed as the "journal"
    /// of preprints, datasets and theses. They are not journals to follow.
    var isRepository = false
    /// OpenAlex's own labels: "article", "review", "preprint", "letter"…
    var openAlexType: String? = nil
    /// "journal", "repository", "conference"…
    var sourceType: String? = nil
    /// PubMed's publication types ("Case Reports", "Review", "Congress"…).
    /// More reliable than anything we can infer, but only papers with a PMID have them.
    var pubmedTypes: [String] = []
    var abstractFromPubMed = false
    /// yyyy-MM-dd
    var date: String
    var authors: [String] = []
    var authorIDs: [String] = []
    /// The institution OpenAlex lists for the first and for the last author.
    /// Optional, so a feed cached before these existed still loads.
    var firstInstitution: String? = nil
    var lastInstitution: String? = nil
    /// OpenAlex's h-index for the first and the last author, fetched only when the
    /// user asks for it to count. Optional so an older cache still loads.
    var firstAuthorH: Int? = nil
    var lastAuthorH: Int? = nil
    var citedBy = 0
    var topics: [String] = []
    /// Short OpenAlex ids. Names can be spelled two ways; muting needs the id.
    var topicIDs: [String] = []
    var journalID: String? = nil
    /// OpenAlex's two-year mean citedness of the journal: an open measure close
    /// to the impact factor (which is Clarivate's and not available to us). nil for
    /// repositories and for journals OpenAlex has no figure for. Optional so a
    /// cache written before this existed still loads.
    var journalImpact: Double? = nil
    var isOpenAccess = false
    /// A PDF the source says may be read for free (OpenAlex's best open-access location, or a
    /// Europe PMC full-text link). Optional so a cache written before this existed still loads;
    /// such papers get one at the next full build.
    var pdfURL: String? = nil
    /// ISO 639-1 code as OpenAlex detected it; nil when it did not.
    var language: String? = nil
    /// Why the paper is in the feed, one entry per seed that found it.
    var reasons: [String] = []
    /// Cites a work the user wrote or asked to track.
    var citesYou = false
    /// Found by something the user chose to follow (a journal, an author…), as
    /// opposed to something we inferred from their own papers.
    var followed = false
    /// Listed in the section for what the user follows. Followed, and by something specific
    /// (a journal, a researcher, a keyword). A topic, an institution or a funder is too broad
    /// to list in full (each can name hundreds of papers a month, in every field), so a paper
    /// found only by those is ranked with the rest instead.
    static let broadReasonPrefixes = ["Topic: ", "Institution: ", "Funder: "]

    var isPinned: Bool {
        followed && (reasons.isEmpty || reasons.contains { r in !Paper.broadReasonPrefixes.contains { r.hasPrefix($0) } })
    }

    /// A DOI lookup found no PubMed record, so it is not tried again on every
    /// refresh. Optional so a cache written before this field existed still loads.
    var notInPubMed: Bool? = nil
    /// Which sources returned it ("OpenAlex", "Europe PMC"). Empty in a cache written
    /// before there was more than one, when every paper came from OpenAlex.
    var sources: [String]? = nil
    var sourceNames: [String] { sources ?? [] }

    /// The first and last author's OpenAlex ids, when they can be told for certain:
    /// names and ids are filled separately, so a missing id would shift the list.
    var leadAuthorIDs: (first: String, last: String)? {
        guard !authors.isEmpty, authors.count == authorIDs.count,
              let first = authorIDs.first, let last = authorIDs.last else { return nil }
        return (first, last)
    }

    /// One paper can arrive from several seeds, and from OpenAlex and PubMed;
    /// the DOI is the join key, with the PMID and the OpenAlex id as fallbacks.
    var dedupeKey: String {
        if let doi { return "doi:" + doi }
        if let pmid { return "pmid:" + pmid }
        return "oa:" + id
    }

    var link: URL? {
        if id.hasPrefix("epmc:"), doi == nil, pmid == nil {
            let parts = id.split(separator: ":")
            if parts.count == 3 { return URL(string: "https://europepmc.org/article/\(parts[1])/\(parts[2])") }
        }
        if let doi { return URL(string: "https://doi.org/" + doi) }
        if let pmid { return URL(string: "https://pubmed.ncbi.nlm.nih.gov/" + pmid) }
        return URL(string: "https://openalex.org/" + id)
    }
}

enum Abstract {
    /// OpenAlex stores abstracts as {word: [positions]}. Put each word back at
    /// each of its positions.
    static func rebuild(_ index: [String: [Int]]?) -> String? {
        guard let index, !index.isEmpty else { return nil }
        var slots: [Int: String] = [:]
        for (word, positions) in index {
            for p in positions { slots[p] = word }
        }
        guard let last = slots.keys.max() else { return nil }
        let text = (0...last).compactMap { slots[$0] }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

enum Merge {
    /// Collapse the copies of one paper that different sources (and different
    /// seeds) returned, keeping first-seen order. Two copies are the same paper if
    /// they share a DOI, a PMID or an id, or, for a preprint and the article it
    /// became (which have different DOIs), the same title and first author within
    /// about eighteen months. The reasons add up; a field one copy lacks is filled
    /// from another.
    static func combine(_ papers: [Paper]) -> [Paper] {
        var parent = Array(papers.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var seen: [String: Int] = [:]
        for (i, p) in papers.enumerated() {
            for key in identityKeys(p) {
                guard let j = seen[key] else { seen[key] = i; continue }
                if key.hasPrefix("t:") && !withinPreprintLag(papers[i].date, papers[j].date) { continue }
                union(i, j)
            }
        }
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in papers.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(i)
        }
        return order.map { fold(groups[$0]!.map { papers[$0] }) }
    }

    private static func identityKeys(_ p: Paper) -> [String] {
        var keys = ["id:" + p.id]
        if let doi = p.doi { keys.append("doi:" + doi) }
        if let pmid = p.pmid { keys.append("pmid:" + pmid) }
        if let surname = firstSurname(p), normalisedTitle(p.title).count >= 25 {
            keys.append("t:" + normalisedTitle(p.title) + "|" + surname)
        }
        return keys
    }

    /// Lower case letters and digits only, so punctuation, case and spacing differences vanish.
    static func normalisedTitle(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// "Gazerani P" and "Parisa Gazerani" both give "gazerani": a surname first
    /// with initials after, or last.
    static func firstSurname(_ p: Paper) -> String? {
        guard let name = p.authors.first else { return nil }
        let words = name.split(separator: " ").map(String.init)
        guard let first = words.first, let last = words.last else { return nil }
        // Initials only ("P", "PM") mark the surname-first form.
        let surname = (words.count > 1 && last.count <= 2 && last == last.uppercased()) ? first : last
        let folded = surname.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter(\.isLetter)
        return folded.isEmpty ? nil : folded
    }

    private static func withinPreprintLag(_ a: String, _ b: String) -> Bool {
        guard let x = Ranker.ageInDays(a, today: Date()), let y = Ranker.ageInDays(b, today: Date()) else { return true }
        return abs(x - y) <= 548
    }

    private static func priority(_ p: Paper) -> Int {
        // The article beats its preprint, so the identity (and the DOI the user's
        // history is keyed on) does not change when a preprint gets published.
        (p.isRepository ? 0 : 2) + (p.sourceNames.isEmpty || p.sourceNames.contains(SourceKind.openAlex.rawValue) ? 1 : 0)
    }

    private static func fold(_ group: [Paper]) -> Paper {
        guard group.count > 1 else { return group[0] }
        // max(by:) keeps the first of equals, so the earliest copy wins a tie.
        let baseIndex = group.indices.max { priority(group[$0]) < priority(group[$1]) }!
        var kept = group[baseIndex]
        for (i, p) in group.enumerated() where i != baseIndex {
            for r in p.reasons where !kept.reasons.contains(r) { kept.reasons.append(r) }
            for s in p.sourceNames where !kept.sourceNames.contains(s) { kept.sources = kept.sourceNames + [s] }
            kept.citesYou = kept.citesYou || p.citesYou
            kept.followed = kept.followed || p.followed
            kept.isOpenAccess = kept.isOpenAccess || p.isOpenAccess
            kept.citedBy = max(kept.citedBy, p.citedBy)
            if kept.abstract == nil, let a = p.abstract { kept.abstract = a; kept.abstractFromPubMed = p.abstractFromPubMed }
            if kept.doi == nil { kept.doi = p.doi }
            if kept.pmid == nil { kept.pmid = p.pmid }
            if kept.journal == nil { kept.journal = p.journal }
            if kept.journalID == nil { kept.journalID = p.journalID }
            if kept.journalImpact == nil { kept.journalImpact = p.journalImpact }
            if kept.firstInstitution == nil { kept.firstInstitution = p.firstInstitution }
            if kept.lastInstitution == nil { kept.lastInstitution = p.lastInstitution }
            if kept.firstAuthorH == nil { kept.firstAuthorH = p.firstAuthorH }
            if kept.lastAuthorH == nil { kept.lastAuthorH = p.lastAuthorH }
            if kept.pdfURL == nil { kept.pdfURL = p.pdfURL }
            if kept.language == nil { kept.language = p.language }
            if kept.pubmedTypes.isEmpty { kept.pubmedTypes = p.pubmedTypes }
            if kept.openAlexType == nil { kept.openAlexType = p.openAlexType }
            if kept.notInPubMed == nil { kept.notInPubMed = p.notInPubMed }
            // OpenAlex's authors and topics carry ids, which muting and the h-index need;
            // take them together with their names so the two lists stay in step.
            if kept.authorIDs.isEmpty, !p.authorIDs.isEmpty { kept.authors = p.authors; kept.authorIDs = p.authorIDs }
            if kept.topicIDs.isEmpty, !p.topicIDs.isEmpty { kept.topics = p.topics; kept.topicIDs = p.topicIDs }
        }
        return kept
    }
}
