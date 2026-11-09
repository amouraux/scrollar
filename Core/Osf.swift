import Foundation

// The Open Science Framework's preprint servers: PsyArXiv, SocArXiv, EdArXiv, OSF Preprints and a
// few dozen more, which matter most to psychology and the social and behavioural sciences. Europe PMC
// carries some of them but not all, and OpenAlex lags. No key. It answers a phrase in titles and
// abstracts, and nothing else (a preprint's contributors cannot be searched). Pure and tested; the
// call is in OsfClient.swift.

enum OsfQuery {
    static let base = "https://api.osf.io/v2/preprints/"

    /// The request parameters for one seed, or nil when OSF cannot answer it. Further conditions of a
    /// keyword (`also`) cannot be put to OSF, one value to a filter, so the parser checks them.
    static func build(_ seed: Seed, since: String, until: String, page: Int = 1, size: Int = 50) -> [URLQueryItem]? {
        guard case .keyword(let phrase, _) = seed else { return nil }
        return [
            URLQueryItem(name: "filter[title,description][icontains]", value: phrase),
            URLQueryItem(name: "filter[date_created][gte]", value: since),
            // A bare date means the start of that day, which would leave out everything posted on it.
            URLQueryItem(name: "filter[date_created][lte]", value: until + "T23:59:59"),
            URLQueryItem(name: "sort", value: "-date_created"),
            URLQueryItem(name: "embed", value: "contributors"),
            URLQueryItem(name: "page[size]", value: String(size)),
            URLQueryItem(name: "page", value: String(page)),
        ]
    }
}

enum OsfParser {
    static func total(in data: Data) -> Int {
        ((((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["links"] as? [String: Any])?["meta"] as? [String: Any])?["total"] as? Int) ?? 0
    }

    static func hasNext(in data: Data) -> Bool {
        ((((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["links"] as? [String: Any])?["next"]) as? String) != nil
    }

    /// The papers in an answer. A preprint has a record for each version ("mnj6b_v1", "mnj6b_v2"); the
    /// answer is newest first, so the first of each is kept and the paper is known without its version.
    static func papers(from data: Data, seed: Seed) -> [Paper] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var out: [Paper] = []
        for item in items {
            guard let paper = paper(item), seen.insert(paper.id).inserted else { continue }
            if case .keyword(let k, let also) = seed {
                let text = AuthorName.fold(paper.title + " " + (paper.abstract ?? ""))
                guard ([k] + also).allSatisfy({ text.contains(AuthorName.fold($0)) }) else { continue }
            }
            out.append(paper)
        }
        return out
    }

    static func withoutVersion(_ id: String) -> String {
        id.replacingOccurrences(of: #"_v\d+$"#, with: "", options: .regularExpression)
    }

    /// What a server is called, from the id OSF gives it.
    static func serverName(_ id: String) -> String {
        let known = ["psyarxiv": "PsyArXiv", "socarxiv": "SocArXiv", "osf": "OSF Preprints", "edarxiv": "EdArXiv",
                     "engrxiv": "engrXiv", "eartharxiv": "EarthArXiv", "lawarxiv": "LawArXiv", "paleorxiv": "PaleorXiv",
                     "mediarxiv": "MediArXiv", "marxiv": "MarXiv", "africarxiv": "AfricArXiv", "nutrixiv": "NutriXiv",
                     "sportrxiv": "SportRxiv", "lissa": "LISSA", "ecsarxiv": "ECSarXiv", "thesiscommons": "Thesis Commons"]
        return known[id] ?? id.capitalized
    }

    static func paper(_ item: [String: Any]) -> Paper? {
        guard let rawID = item["id"] as? String, let a = item["attributes"] as? [String: Any],
              let rawTitle = a["title"] as? String else { return nil }
        // Withdrawn or never published: not a paper to read.
        if a["is_published"] as? Bool == false || (a["date_withdrawn"] as? String) != nil { return nil }
        let title = Html.plain(rawTitle)
        guard !title.isEmpty, let created = (a["date_created"] as? String) ?? (a["date_published"] as? String), created.count >= 10 else { return nil }
        let id = withoutVersion(rawID)
        let links = item["links"] as? [String: Any]
        let doiText = (links?["preprint_doi"] as? String).map { $0.replacingOccurrences(of: "https://doi.org/", with: "") }
        let doi = Identifiers.doi(doiText.map(withoutVersion))
        let provider = (((item["relationships"] as? [String: Any])?["provider"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
        // Contributors come embedded, each with the user's record; only those named as authors, in order.
        let embedded = (((item["embeds"] as? [String: Any])?["contributors"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        let people: [(index: Int, name: String)] = embedded.compactMap { c in
            let attributes = c["attributes"] as? [String: Any]
            guard attributes?["bibliographic"] as? Bool != false,
                  let user = (((c["embeds"] as? [String: Any])?["users"] as? [String: Any])?["data"] as? [String: Any])?["attributes"] as? [String: Any],
                  let name = user["full_name"] as? String, !name.isEmpty else { return nil }
            return ((attributes?["index"] as? Int) ?? 0, name)
        }
        let abstract = (a["description"] as? String).map(Html.plain).flatMap { $0.isEmpty ? nil : $0 }
        return Paper(
            id: "osf:\(id)",
            doi: doi,
            title: title,
            abstract: abstract,
            journal: provider.map(serverName) ?? "OSF Preprints",
            isRepository: true,
            openAlexType: "preprint",
            sourceType: "repository",
            date: String(created.prefix(10)),
            authors: people.sorted { $0.index < $1.index }.map(\.name),
            isOpenAccess: true,
            pdfURL: "https://osf.io/\(id)/download",
            sources: [SourceKind.osf.rawValue]
        )
    }
}
