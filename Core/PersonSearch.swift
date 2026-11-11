import Foundation

// Finding someone's ORCID iD from their name, so that nobody has to know their own by heart.
// Pure: the requests are in `PersonSearchClient.swift`. The iD is only an identifier here: it comes
// out of Europe PMC's and OpenAlex's own records. ORCID's API (pub.orcid.org) is never asked, because
// its public licence is non-commercial (see the README).

/// A name as someone types it, reduced to what both sources can be asked and what a candidate can
/// be checked against.
struct PersonName: Equatable {
    /// Empty when only the initials are known: "A" and "Jean-Pierre" are both given names.
    var given: String
    var family: String

    private static let particles: Set<String> = ["van", "von", "de", "der", "den", "del", "della", "di", "da", "dos", "du",
                                                  "le", "la", "ten", "ter", "bin", "ibn", "al", "el", "st"]

    /// "André Mouraux", "A. Mouraux", "Mouraux A", "Mouraux, André" and "Ludwig van der Berg" are all
    /// understood. nil for a single word: a family name alone names hundreds of people, and the
    /// search would be an answer to nothing.
    static func parse(_ text: String) -> PersonName? {
        let cleaned = text.replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        if let comma = cleaned.firstIndex(of: ",") {
            let family = String(cleaned[..<comma]).trimmingCharacters(in: .whitespaces)
            let given = String(cleaned[cleaned.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            return family.isEmpty || given.isEmpty ? nil : PersonName(given: given, family: family)
        }
        let words = cleaned.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        // Europe PMC's own form, family first and then capital initials: "Mouraux A", "Kandel ER".
        if let last = words.last, last.count <= 3, last.allSatisfy({ $0.isUppercase }), words.count == 2,
           !(words[0].count <= 3 && words[0].allSatisfy { $0.isUppercase }) {
            return PersonName(given: last, family: words[0])
        }
        var start = words.count - 1
        while start > 1, particles.contains(words[start - 1].lowercased()) { start -= 1 }
        return PersonName(given: words[..<start].joined(separator: " "), family: words[start...].joined(separator: " "))
    }

    // MARK: Comparing

    /// Case, accents, hyphens and apostrophes ignored: "Müller-Ström" and "muller strom" are one name.
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The words of a given name, folded; capital letters run together ("JS", "JP") are initials.
    private static func parts(_ given: String) -> [String] {
        given.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).flatMap { token -> [String] in
            let word = String(token)
            if word.count > 1, word.count <= 3, word.allSatisfy({ $0.isUppercase }) { return word.map { folded(String($0)) } }
            return [folded(word)]
        }.filter { !$0.isEmpty }
    }

    /// Whether a name from a record can be this person. Strict about the family name, tolerant of
    /// the given name, which a record often gives as initials only ("Mouraux A").
    func accepts(given candidateGiven: String, family candidateFamily: String) -> Bool {
        let ours = Self.folded(family), theirs = Self.folded(candidateFamily)
        // "van der Berg" is "Berg" in one record and "van der Berg" in another.
        guard !ours.isEmpty, ours == theirs || ours.hasSuffix(" " + theirs) || theirs.hasSuffix(" " + ours) else { return false }
        let a = Self.parts(given), b = Self.parts(candidateGiven)
        guard let a1 = a.first, let b1 = b.first else { return true }
        guard a1.first == b1.first else { return false }
        let initialsOnly: ([String]) -> Bool = { $0.allSatisfy { $0.count == 1 } }
        if initialsOnly(a) || initialsOnly(b) {
            let x = a.map { String($0.first!) }.joined(), y = b.map { String($0.first!) }.joined()
            return x.hasPrefix(y) || y.hasPrefix(x)
        }
        return a1.hasPrefix(b1) || b1.hasPrefix(a1)
    }

    /// Europe PMC's author query: the family name and the first initial, which is how it indexes names.
    var europePMCAuthor: String {
        let initial = Self.folded(given).first.map { String($0).uppercased() } ?? ""
        let family = self.family.replacingOccurrences(of: "\"", with: "")
        return "\(family) \(initial)".trimmingCharacters(in: .whitespaces)
    }
}

/// Someone a name search found, with enough to tell them from a namesake.
struct PersonCandidate: Identifiable, Equatable {
    /// Checked: always in the form 0000-0000-0000-0000 with a valid check character.
    var orcid: String
    var name: String
    var affiliation: String?
    /// How many works the source lists for this person (OpenAlex), nil when it does not say.
    var works: Int?
    /// How many of the papers read in Europe PMC carry this iD.
    var papersSeen: Int
    var latestTitle: String?
    var latestYear: Int?
    /// What the person writes about most (OpenAlex).
    var topic: String?
    var inOpenAlex = false
    var inEuropePMC = false

    var id: String { orcid }

    /// One line under the name: where they work and how much they have published.
    var summaryLine: String {
        var parts: [String] = []
        if let affiliation { parts.append(affiliation) }
        if let works { parts.append(works == 1 ? "1 work" : "\(works) works") }
        else if papersSeen > 0 { parts.append(papersSeen == 1 ? "1 paper found" : "\(papersSeen) papers found") }
        if let topic { parts.append(topic) }
        return parts.joined(separator: " · ")
    }

    /// A recent paper, so that someone who knows their own work can recognise themselves.
    var latestLine: String? {
        guard let latestTitle else { return nil }
        return "Recent: " + latestTitle + (latestYear.map { " (\($0))" } ?? "")
    }
}

enum PersonSearch {
    /// How many candidates are listed. More than this is a surname, not a search.
    static let limit = 8

    // MARK: Europe PMC (no key)

    /// Papers by this name where some author carries an iD. Europe PMC links an iD to an author only
    /// where the paper's record says so, so a person is found by the papers that carry theirs.
    static func europePMCQuery(for name: PersonName) -> String {
        "AUTH:\"\(name.europePMCAuthor)\" AND AUTHORID:*"
    }

    /// The people with an iD in a `resultType=core` response, whose name fits, newest paper first.
    static func europePMC(_ data: Data, name: PersonName) -> [PersonCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["resultList"] as? [String: Any])?["result"] as? [[String: Any]] else { return [] }
        var found: [String: PersonCandidate] = [:]
        var order: [String] = []
        for record in list {
            let title = (record["title"] as? String).map { Html.plain($0).trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            let year = (record["pubYear"] as? String).flatMap(Int.init)
            let authors = ((record["authorList"] as? [String: Any])?["author"] as? [[String: Any]]) ?? []
            for a in authors {
                guard let id = a["authorId"] as? [String: Any], (id["type"] as? String)?.uppercased() == "ORCID",
                      let raw = id["value"] as? String, let orcid = Orcid.normalised(raw) else { continue }
                let given = (a["firstName"] as? String) ?? (a["initials"] as? String) ?? ""
                let family = (a["lastName"] as? String) ?? ""
                guard !family.isEmpty, name.accepts(given: given, family: family) else { continue }
                if found[orcid] == nil {
                    let details = ((a["authorAffiliationDetailsList"] as? [String: Any])?["authorAffiliation"] as? [[String: Any]]) ?? []
                    let place = details.compactMap { $0["affiliation"] as? String }.compactMap(Affiliation.institution).first
                    found[orcid] = PersonCandidate(orcid: orcid, name: "\(given) \(family)".trimmingCharacters(in: .whitespaces),
                                                   affiliation: place, papersSeen: 0, latestTitle: title, latestYear: year,
                                                   inEuropePMC: true)
                    order.append(orcid)
                }
                found[orcid]?.papersSeen += 1
                // Records come newest first, but one without an affiliation says nothing about where.
                if found[orcid]?.affiliation == nil {
                    let details = ((a["authorAffiliationDetailsList"] as? [String: Any])?["authorAffiliation"] as? [[String: Any]]) ?? []
                    found[orcid]?.affiliation = details.compactMap { $0["affiliation"] as? String }.compactMap(Affiliation.institution).first
                }
            }
        }
        return order.compactMap { found[$0] }
    }

    // MARK: OpenAlex (the user's key)

    /// The query items for OpenAlex's author search, restricted to people who have an iD, because an
    /// author with none cannot be chosen.
    static func openAlexQuery(for name: PersonName) -> [String: String] {
        ["search": [name.given, name.family].filter { !$0.isEmpty }.joined(separator: " "),
         "filter": "has_orcid:true", "per-page": "10",
         "select": "id,display_name,orcid,works_count,last_known_institutions,topics"]
    }

    static func openAlex(_ data: Data) -> [PersonCandidate] {
        struct Response: Decodable {
            var results: [Author]
            struct Author: Decodable {
                var display_name: String?
                var orcid: String?
                var works_count: Int?
                var last_known_institutions: [Institution]?
                var topics: [Topic]?
            }
            struct Institution: Decodable { var display_name: String? }
            struct Topic: Decodable { var display_name: String? }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.results.compactMap { a in
            guard let raw = a.orcid, let orcid = Orcid.normalised(raw), let name = a.display_name else { return nil }
            return PersonCandidate(orcid: orcid, name: name,
                                   affiliation: a.last_known_institutions?.compactMap(\.display_name).first,
                                   works: a.works_count, papersSeen: 0,
                                   topic: a.topics?.compactMap(\.display_name).first, inOpenAlex: true)
        }
    }

    // MARK: Both

    /// One list: a person both sources know is one row, with the works count of OpenAlex and the
    /// recent paper of Europe PMC. Those both sources know come first, then the ones with most work.
    static func merge(_ lists: [[PersonCandidate]]) -> [PersonCandidate] {
        var byID: [String: PersonCandidate] = [:]
        var order: [String] = []
        for candidate in lists.joined() {
            guard var kept = byID[candidate.orcid] else {
                byID[candidate.orcid] = candidate
                order.append(candidate.orcid)
                continue
            }
            kept.inOpenAlex = kept.inOpenAlex || candidate.inOpenAlex
            kept.inEuropePMC = kept.inEuropePMC || candidate.inEuropePMC
            kept.affiliation = kept.affiliation ?? candidate.affiliation
            kept.works = kept.works ?? candidate.works
            kept.topic = kept.topic ?? candidate.topic
            kept.papersSeen = max(kept.papersSeen, candidate.papersSeen)
            if kept.latestTitle == nil { kept.latestTitle = candidate.latestTitle; kept.latestYear = candidate.latestYear }
            byID[candidate.orcid] = kept
        }
        let ranked = order.compactMap { byID[$0] }
        let indexed = ranked.enumerated().sorted { l, r in
            let (a, b) = (l.element, r.element)
            let both = (a.inOpenAlex && a.inEuropePMC, b.inOpenAlex && b.inEuropePMC)
            if both.0 != both.1 { return both.0 }
            let size = (a.works ?? a.papersSeen, b.works ?? b.papersSeen)
            return size.0 != size.1 ? size.0 > size.1 : l.offset < r.offset
        }
        return Array(indexed.map(\.element).prefix(limit))
    }

    // MARK: What to tell the person

    /// Plain words under the list: how many people, and that a namesake is a different person.
    static func verdict(_ candidates: [PersonCandidate], asked: [String]) -> String {
        let where_ = asked.joined(separator: " and ")
        switch candidates.count {
        case 0:
            return "No one with that name has an ORCID iD in \(where_). Try the name as it appears on your papers, or look it up on orcid.org."
        case 1:
            return "One person matches. Check the institution and the paper before choosing."
        default:
            return "\(candidates.count) different people match this name. They are not the same person: tell them apart by institution and by papers you recognise."
        }
    }

    /// Said under the list when only Europe PMC was asked.
    static let withoutOpenAlex = "Only Europe PMC was asked, which knows an iD only where a paper carries it. A free OpenAlex key (Tune, Sources) finds more people."
}

/// Where to look a person up when the search does not find them, on ORCID's own website, in a browser.
/// A page, not the API.
enum OrcidLookup {
    /// Where someone without an iD makes one: free, and it takes a minute.
    static let registerURL = URL(string: "https://orcid.org/register")!

    static func pageURL(name: String) -> URL? {
        var parts = URLComponents(string: "https://orcid.org/orcid-search/search")
        parts?.queryItems = [URLQueryItem(name: "searchQuery", value: name.trimmingCharacters(in: .whitespacesAndNewlines))]
        return parts?.url
    }
}
