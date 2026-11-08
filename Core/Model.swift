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
    /// ISO 639-1 code as OpenAlex detected it; nil when it did not.
    var language: String? = nil
    /// Why the paper is in the feed, one entry per seed that found it.
    var reasons: [String] = []
    /// Cites a work the user wrote or asked to track.
    var citesYou = false
    /// Found by something the user chose to follow (a journal, an author…), as
    /// opposed to something we inferred from their own papers.
    var followed = false
    /// A DOI lookup found no PubMed record, so it is not tried again on every
    /// refresh. Optional so a cache written before this field existed still loads.
    var notInPubMed: Bool? = nil

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
    /// Collapse duplicates, keeping first-seen order. The reasons add up; a
    /// field one copy lacks (usually the abstract) is filled from the other.
    static func combine(_ papers: [Paper]) -> [Paper] {
        var byKey: [String: Paper] = [:]
        var order: [String] = []
        for p in papers {
            let key = p.dedupeKey
            guard var kept = byKey[key] else {
                byKey[key] = p
                order.append(key)
                continue
            }
            for r in p.reasons where !kept.reasons.contains(r) { kept.reasons.append(r) }
            kept.citesYou = kept.citesYou || p.citesYou
            kept.followed = kept.followed || p.followed
            if kept.abstract == nil { kept.abstract = p.abstract }
            if kept.journalImpact == nil { kept.journalImpact = p.journalImpact }
            if kept.firstAuthorH == nil { kept.firstAuthorH = p.firstAuthorH }
            if kept.lastAuthorH == nil { kept.lastAuthorH = p.lastAuthorH }
            if kept.pmid == nil { kept.pmid = p.pmid }
            if kept.doi == nil { kept.doi = p.doi }
            if kept.firstInstitution == nil { kept.firstInstitution = p.firstInstitution }
            if kept.lastInstitution == nil { kept.lastInstitution = p.lastInstitution }
            byKey[key] = kept
        }
        return order.compactMap { byKey[$0] }
    }
}
