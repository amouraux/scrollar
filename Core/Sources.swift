import Foundation

// More than one place to ask. Everything here is pure: what to ask each source
// for a seed, and how to read what comes back. The network halves are
// EuropePMCClient.

/// The places a paper can come from. The raw value is what is stored on the
/// paper and shown as "found in".
enum SourceKind: String, CaseIterable, Codable {
    case openAlex = "OpenAlex"
    case europePMC = "Europe PMC"
    case crossref = "Crossref"
    case arXiv = "arXiv"
}

enum SourceRouting {
    /// OpenAlex short ids ("W2741809807"). Papers from other sources carry ids of
    /// their own, and a seed built from those cannot be put to OpenAlex.
    static func isOpenAlexID(_ id: String) -> Bool {
        guard let first = id.first, first.isLetter else { return false }
        return id.dropFirst().allSatisfy(\.isNumber) && id.count > 1
    }

    /// Entities added by typing a name carry this prefix instead of an OpenAlex id.
    static func isNamed(_ id: String) -> Bool { id.hasPrefix("name:") }

    static func namedID(_ name: String) -> String { "name:" + name }

    /// Which sources can answer a seed. A seed an OpenAlex id answers precisely is
    /// not asked again by name elsewhere while OpenAlex is on: names are ambiguous.
    /// With OpenAlex off, the same seeds fall back to their names.
    ///
    /// Crossref is the keyless way outside biomedicine, so it is asked only when OpenAlex is off. arXiv
    /// is asked about what it can answer, a phrase and an author's name, beside whatever else is on.
    static func targets(for seed: Seed, openAlex: Bool, europePMC: Bool, crossref: Bool = false, arXiv: Bool = false,
                        hasOwnPMIDs: Bool) -> [SourceKind] {
        var out: [SourceKind] = []
        func offerEurope(_ ok: Bool) { if europePMC && ok { out.append(.europePMC) } }
        func offerCrossref(_ ok: Bool) { if crossref && !openAlex && ok { out.append(.crossref) } }
        func offerArxiv(_ ok: Bool) { if arXiv && ok { out.append(.arXiv) } }
        switch seed {
        case .keyword:
            if openAlex { out.append(.openAlex) }
            offerEurope(true)
            offerCrossref(true)
            offerArxiv(true)
        case .journal(let id, _):
            if openAlex && !isNamed(id) { out.append(.openAlex) }
            offerEurope(true)
            offerCrossref(true)
        case .mesh:
            offerEurope(true)
        case .topic(let id, _):
            if openAlex && !isNamed(id) { out.append(.openAlex) }
        case .author(let id, _), .institution(let id, _), .funder(let id, _):
            if openAlex && !isNamed(id) { out.append(.openAlex) }
            offerEurope(isNamed(id) || !openAlex)
            if case .author = seed { offerCrossref(true); offerArxiv(isNamed(id) || !openAlex) }
        case .cites(let ids, let label):
            if openAlex && !ids.isEmpty && ids.allSatisfy(isOpenAlexID) { out.append(.openAlex) }
            offerEurope(label == "Cites your work" && hasOwnPMIDs)
        }
        return out
    }
}

enum EuropePMCQuery {
    /// The query for one seed, or nil when Europe PMC cannot answer it.
    /// `since` and `until` are yyyy-MM-dd and bound the first publication date, the
    /// same window the OpenAlex queries use.
    static func build(_ seed: Seed, since: String, until: String, ownPMIDs: [String] = []) -> String? {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: " ") + "\"" }
        func name(_ id: String, _ display: String) -> String { SourceRouting.isNamed(id) ? String(id.dropFirst(5)) : display }
        var base: String
        switch seed {
        case .keyword(let k, let also):
            base = ([k] + also).map { "(TITLE:\(q($0)) OR ABSTRACT:\(q($0)))" }.joined(separator: " AND ")
            if !also.isEmpty { base = "(" + base + ")" }
        case .journal(let id, let n): base = "JOURNAL:\(q(name(id, n)))"
        case .mesh(let n): base = "MESH:\(q(n))"
        case .author(let id, let n): base = "AUTH:\(q(name(id, n)))"
        case .institution(let id, let n): base = "AFF:\(q(name(id, n)))"
        case .funder(let id, let n): base = "GRANT_AGENCY:\(q(name(id, n)))"
        case .topic: return nil
        case .cites:
            guard !ownPMIDs.isEmpty else { return nil }
            base = "(" + ownPMIDs.prefix(40).map { "CITES:\($0)_MED" }.joined(separator: " OR ") + ")"
        }
        return "\(base) AND FIRST_PDATE:[\(since) TO \(until)]"
    }
}

// MARK: - Reading Europe PMC

extension EuropePMCQuery {
    /// The papers whose author list carries this ORCID iD. The iD is only an identifier here, a
    /// key into Europe PMC's own records; ORCID's own API is not used (its public licence is
    /// non-commercial).
    static func orcid(_ iD: String) -> String { "AUTHORID:\"\(iD)\"" }
}

enum EuropePMCParser {
    /// The name Europe PMC gives the author who carries this ORCID iD in a response: the given and
    /// family names where it has them, else the "Mouraux A" form.
    static func authorName(orcid: String, in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["resultList"] as? [String: Any])?["result"] as? [[String: Any]] else { return nil }
        for record in list {
            let authors = ((record["authorList"] as? [String: Any])?["author"] as? [[String: Any]]) ?? []
            for a in authors where ((a["authorId"] as? [String: Any])?["value"] as? String) == orcid {
                let given = (a["firstName"] as? String) ?? ""
                let family = (a["lastName"] as? String) ?? ""
                let full = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
                return full.isEmpty ? a["fullName"] as? String : full
            }
        }
        return nil
    }

    /// Papers from a `resultType=core` JSON response.
    static func papers(from data: Data) -> [Paper] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["resultList"] as? [String: Any])?["result"] as? [[String: Any]] else { return [] }
        return list.compactMap(paper)
    }

    static func hitCount(in data: Data) -> Int {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hitCount"] as? Int) ?? 0
    }

    static func paper(_ r: [String: Any]) -> Paper? {
        guard let source = r["source"] as? String, let id = r["id"] as? String,
              let rawTitle = r["title"] as? String else { return nil }
        let title = Html.plain(rawTitle).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let date = (r["firstPublicationDate"] as? String)
            ?? (r["pubYear"] as? String).map { "\($0)-01-01" }
        guard !title.isEmpty, let date else { return nil }

        let preprint = source == "PPR"
        let journalInfo = r["journalInfo"] as? [String: Any]
        let journalTitle = ((journalInfo?["journal"] as? [String: Any])?["title"] as? String)
            ?? ((r["bookOrReportDetails"] as? [String: Any])?["publisher"] as? String)
        let authorList = ((r["authorList"] as? [String: Any])?["author"] as? [[String: Any]]) ?? []
        let names = authorList.compactMap { $0["fullName"] as? String }
        func institution(_ a: [String: Any]?) -> String? {
            let details = ((a?["authorAffiliationDetailsList"] as? [String: Any])?["authorAffiliation"] as? [[String: Any]]) ?? []
            return details.compactMap { $0["affiliation"] as? String }.compactMap(Affiliation.institution).first
        }
        let pubTypes = ((r["pubTypeList"] as? [String: Any])?["pubType"] as? [String]) ?? []
        let mesh = ((r["meshHeadingList"] as? [String: Any])?["meshHeading"] as? [[String: Any]]) ?? []

        return Paper(
            id: "epmc:\(source):\(id)",
            doi: Identifiers.doi(r["doi"] as? String),
            pmid: (r["pmid"] as? String) ?? (source == "MED" ? id : nil),
            title: title,
            abstract: (r["abstractText"] as? String).map(Html.plain).flatMap { $0.isEmpty ? nil : $0 },
            journal: journalTitle,
            isRepository: preprint,
            openAlexType: preprint ? "preprint" : nil,
            sourceType: preprint ? "repository" : "journal",
            pubmedTypes: pubTypes,
            date: date,
            authors: names,
            firstInstitution: institution(authorList.first),
            lastInstitution: institution(authorList.last),
            citedBy: (r["citedByCount"] as? Int) ?? 0,
            topics: Array(mesh.compactMap { $0["descriptorName"] as? String }.filter { !MeSH.isGeneric($0) }.prefix(6)),
            isOpenAccess: (r["isOpenAccess"] as? String) == "Y",
            pdfURL: PDFLink.europePMC(r),
            language: Languages.iso1(r["language"] as? String),
            sources: [SourceKind.europePMC.rawValue]
        )
    }
}

enum MeSH {
    /// Headings every study carries ("Humans", "Adult", "Mice") or that name a study
    /// design: as topics they say nothing, and as a search they match half of PubMed.
    private static let generic: Set<String> = [
        "humans", "animals", "male", "female", "adult", "aged", "aged, 80 and over", "middle aged", "young adult",
        "adolescent", "child", "child, preschool", "infant", "infant, newborn", "mice", "rats", "pregnancy",
        "retrospective studies", "prospective studies", "cross-sectional studies", "cohort studies",
        "case-control studies", "follow-up studies", "treatment outcome", "risk factors", "time factors",
        "surveys and questionnaires", "reproducibility of results", "models, animal", "disease models, animal",
        "mice, inbred c57bl", "randomized controlled trials as topic", "double-blind method", "sex factors",
        "age factors", "severity of illness index", "quality of life", "prognosis", "incidence",
    ]

    static func isGeneric(_ heading: String) -> Bool { generic.contains(heading.lowercased()) }
}

enum Html {
    /// Europe PMC abstracts carry markup ("<i>Objective.</i>Tumor stiffness…",
    /// "<h4>Background</h4>"). Block tags become spaces, the rest vanish.
    static func plain(_ s: String) -> String {
        var t = s
        if t.contains("<") {
            t = t.replacingOccurrences(of: #"</?(h\d|p|br|li|ul|ol|div|sec|title)[^>]*>"#, with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        }
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension Paper {
    /// Titles and abstracts from OpenAlex and Crossref-fed journals carry markup ("<i>In Silico</i>")
    /// and entities. A feed cached before they were cleaned still holds them, so this is applied
    /// when one is loaded as well as when a record is read.
    var withPlainText: Paper {
        var p = self
        if title.contains("<") || title.contains("&") { p.title = Html.plain(title) }
        if let a = abstract, a.contains("<") || a.contains("&") { p.abstract = Html.plain(a) }
        return p
    }
}

enum Affiliation {
    private static let markers = ["universit", "institut", "hospital", "college", "école", "ecole", "centre",
                                  "center", "clinic", "academy", "laborator", "school of", "medical school",
                                  "research council", "max planck", "inserm", "cnrs"]

    /// "Department of Life Sciences, Oslo Metropolitan University, Oslo, Norway."
    /// -> "Oslo Metropolitan University". The first segment that names an
    /// institution, since the department comes before it and the town after.
    static func institution(from raw: String) -> String? {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))) }
        // "Department of …" and "Faculty of …" often contain "Institute" or "School" too.
        let skipPrefixes = ["department", "dept", "faculty", "division", "section", "unit", "laboratory of", "school of", "centre for", "center for"]
        for part in parts where !part.isEmpty {
            let lower = part.lowercased()
            if skipPrefixes.contains(where: lower.hasPrefix) { continue }
            if markers.contains(where: lower.contains) { return part }
        }
        return nil
    }
}

enum Languages {
    private static let table = ["eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es",
                                "ita": "it", "por": "pt", "dut": "nl", "nld": "nl", "rus": "ru", "chi": "zh",
                                "zho": "zh", "jpn": "ja", "pol": "pl", "tur": "tr", "kor": "ko", "ara": "ar", "hin": "hi",
                                "swe": "sv", "dan": "da", "nor": "no", "fin": "fi", "cze": "cs", "ces": "cs",
                                "hun": "hu", "gre": "el", "ell": "el", "heb": "he", "ind": "id", "vie": "vi",
                                "tha": "th", "ukr": "uk", "rum": "ro", "ron": "ro", "cat": "ca", "per": "fa",
                                "fas": "fa", "hrv": "hr", "srp": "sr", "slv": "sl", "bul": "bg"]

    /// Europe PMC uses three-letter codes; the language filter uses two.
    static func iso1(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        return code.count == 2 ? code : table[code]
    }
}
