import Foundation

struct AuthorProfile {
    var id: String
    var name: String
    var worksCount: Int
    var citedByCount: Int
    var hIndex: Int?
    /// Most-used first, ids shortened ("T10574").
    var topics: [(id: String, name: String, count: Int)]
}

enum OpenAlexError: Error, CustomStringConvertible {
    case http(Int, String)
    case notFound(String)

    var description: String {
        switch self {
        case .http(let code, let body): return "OpenAlex answered HTTP \(code): \(body.prefix(200))"
        case .notFound(let what): return "OpenAlex has no record of \(what)"
        }
    }
}

/// The only file that talks to the network. The key goes in a query item and
/// is never part of an error message or a log line.
struct OpenAlexClient {
    let apiKey: String
    var session: URLSession = .shared

    private static let workFields = [
        "id", "doi", "title", "publication_date", "primary_location", "authorships",
        "cited_by_count", "abstract_inverted_index", "ids", "topics", "type",
        "open_access", "language",
    ].joined(separator: ",")

    // MARK: Requests

    private func fetch(_ path: String, _ query: [String: String]) async throws -> Data {
        guard var comps = URLComponents(string: "https://api.openalex.org/" + path) else {
            throw OpenAlexError.notFound(path)
        }
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        comps.queryItems = items
        guard let url = comps.url else { throw OpenAlexError.notFound(path) }

        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw OpenAlexError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func author(orcid: String) async throws -> AuthorProfile {
        let data = try await fetch("authors/https://orcid.org/\(orcid)", [:])
        let a = try JSONDecoder().decode(AuthorDTO.self, from: data)
        return AuthorProfile(
            id: Identifiers.openAlexID(a.id),
            name: a.display_name ?? orcid,
            worksCount: a.works_count ?? 0,
            citedByCount: a.cited_by_count ?? 0,
            hIndex: a.summary_stats?.h_index,
            topics: (a.topics ?? []).compactMap { t in
                guard let id = t.id, let name = t.display_name else { return nil }
                return (Identifiers.openAlexID(id), name, t.count ?? 0)
            }
        )
    }

    func works(filter: String, perPage: Int, sort: String = "publication_date:desc", page: Int = 1) async throws -> [Paper] {
        let data = try await fetch("works", [
            "filter": filter,
            "per-page": String(perPage),
            "page": String(page),
            "sort": sort,
            "select": Self.workFields,
        ])
        return try JSONDecoder().decode(WorksDTO.self, from: data).results.compactMap(\.paper)
    }

    /// A person's most recent papers, reduced to what can be followed: topics, the journal,
    /// co-authors, where they themselves worked, and the funders. `authorID` is theirs, so
    /// they are left out of their own co-authors and their own affiliations are told apart.
    func profileWorks(authorID: String, perPage: Int = 100) async throws -> [ProfileWork] {
        let data = try await fetch("works", [
            "filter": "author.id:\(authorID)",
            "per-page": String(perPage),
            "sort": "publication_date:desc",
            "select": "id,publication_date,primary_location,authorships,topics,awards",
        ])
        return try JSONDecoder().decode(ProfileWorksDTO.self, from: data).results.compactMap { $0.profileWork(me: authorID) }
    }

    /// How many papers each journal has published in all, by id. A general journal with a
    /// hundred thousand is not something to follow in full.
    func journalSizes(ids: [String]) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            let data = try await fetch("sources", [
                "filter": "openalex:" + batch.joined(separator: "|"),
                "per-page": "100",
                "select": "id,works_count",
            ])
            for source in try JSONDecoder().decode(SourceSizesDTO.self, from: data).results {
                if let n = source.works_count { out[Identifiers.openAlexID(source.id)] = n }
            }
        }
        return out
    }

    /// Two-year mean citedness by journal id, for the journals OpenAlex has a figure
    /// for. One request per hundred journals.
    func journalImpact(ids: [String]) async throws -> [String: Double] {
        var out: [String: Double] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            let data = try await fetch("sources", [
                "filter": "openalex:" + batch.joined(separator: "|"),
                "per-page": "100",
                "select": "id,summary_stats",
            ])
            for source in try JSONDecoder().decode(SourcesDTO.self, from: data).results {
                if let value = source.summary_stats?.citedness {
                    out[Identifiers.openAlexID(source.id)] = value
                }
            }
        }
        return out
    }

    /// h-index by author id, from OpenAlex's own record of each author. One request
    /// per hundred authors.
    func authorHIndex(ids: [String]) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            let data = try await fetch("authors", [
                "filter": "openalex:" + batch.joined(separator: "|"),
                "per-page": "100",
                "select": "id,summary_stats",
            ])
            for author in try JSONDecoder().decode(AuthorsDTO.self, from: data).results {
                if let h = author.summary_stats?.h_index { out[Identifiers.openAlexID(author.id)] = h }
            }
        }
        return out
    }

    enum EntityKind: String, CaseIterable {
        case topics, sources, authors, institutions, funders
    }

    struct EntityHit: Identifiable, Hashable {
        var entity: Entity
        /// What tells two of the same name apart: an author's institution, a
        /// journal's publisher, a topic's description.
        var hint: String?
        var worksCount: Int
        var id: String { entity.id }
    }

    /// Search by name, for the pickers in Settings. Names are ambiguous, so the
    /// user chooses from candidates and what is stored is the id.
    func search(_ kind: EntityKind, query: String) async throws -> [EntityHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let data = try await fetch("autocomplete/\(kind.rawValue)", ["q": q])
        let response = try JSONDecoder().decode(AutocompleteDTO.self, from: data)
        return response.results.compactMap { r in
            guard let name = r.display_name else { return nil }
            return EntityHit(entity: Entity(id: Identifiers.openAlexID(r.id), name: name),
                             hint: r.hint, worksCount: r.works_count ?? 0)
        }
    }

    /// Run one seed, tagging every result with why it is there.
    /// `maxPages` more than 1 keeps asking while a page comes back full, so a long
    /// gap since the last refresh is not cut off at the newest `perPage` papers.
    func papers(for seed: Seed, since: String, perPage: Int = 100, maxPages: Int = 1) async throws -> [Paper] {
        var found: [Paper] = []
        for page in 1...max(maxPages, 1) {
            let batch = try await works(filter: seed.filter(since: since), perPage: perPage, page: page)
            found += batch
            if batch.count < perPage { break }
        }
        for i in found.indices {
            found[i].reasons = [seed.reason]
            found[i].citesYou = seed.citesYou
        }
        return found
    }
}

// MARK: - Wire format

private struct AuthorDTO: Decodable {
    let id: String
    let display_name: String?
    let works_count: Int?
    let cited_by_count: Int?
    let summary_stats: Stats?
    let topics: [Topic]?

    struct Stats: Decodable { let h_index: Int? }
    struct Topic: Decodable { let id: String?; let display_name: String?; let count: Int? }
}

private struct AutocompleteDTO: Decodable {
    let results: [Hit]
    struct Hit: Decodable {
        let id: String
        let display_name: String?
        let hint: String?
        let works_count: Int?
    }
}

private struct SourceSizesDTO: Decodable {
    let results: [Source]
    struct Source: Decodable { let id: String; let works_count: Int? }
}

private struct ProfileWorksDTO: Decodable {
    let results: [Work]

    struct Work: Decodable {
        let publication_date: String?
        let primary_location: Location?
        let authorships: [Authorship]?
        let topics: [Ref]?
        let awards: [Award]?

        struct Location: Decodable { let source: Source? }
        struct Source: Decodable { let id: String?; let display_name: String?; let type: String? }
        struct Authorship: Decodable { let author: Ref?; let institutions: [Ref]? }
        struct Ref: Decodable { let id: String?; let display_name: String? }
        struct Award: Decodable { let funder_id: String?; let funder_display_name: String? }

        private func entity(_ ref: Ref?) -> Entity? {
            guard let id = ref?.id, let name = ref?.display_name, !name.isEmpty else { return nil }
            return Entity(id: Identifiers.openAlexID(id), name: name)
        }

        /// A consortium paper's hundreds of authors say nothing about who the person works with.
        private static let largestTeam = 30

        func profileWork(me: String) -> ProfileWork? {
            guard let year = publication_date.flatMap({ Int($0.prefix(4)) }) else { return nil }
            let team = authorships ?? []
            var work = ProfileWork(year: year)
            work.topics = (topics ?? []).compactMap(entity)
            if let source = primary_location?.source, source.type != "repository" {
                work.journal = entity(Ref(id: source.id, display_name: source.display_name))
            }
            if team.count <= Work.largestTeam {
                work.people = team.compactMap { entity($0.author) }.filter { $0.id != me }
            }
            let mine = team.first { entity($0.author)?.id == me }
            work.institutions = (mine?.institutions ?? []).compactMap(entity)
            work.funders = (awards ?? []).compactMap { entity(Ref(id: $0.funder_id, display_name: $0.funder_display_name)) }
            return work
        }
    }
}

private struct AuthorsDTO: Decodable {
    let results: [Author]
    struct Author: Decodable {
        let id: String
        let summary_stats: Stats?
    }
    struct Stats: Decodable { let h_index: Int? }
}

private struct SourcesDTO: Decodable {
    let results: [Source]
    struct Source: Decodable {
        let id: String
        let summary_stats: Stats?
    }
    struct Stats: Decodable {
        let citedness: Double?
        enum CodingKeys: String, CodingKey { case citedness = "2yr_mean_citedness" }
    }
}

private struct WorksDTO: Decodable {
    let results: [WorkDTO]
}

private struct WorkDTO: Decodable {
    let id: String
    let doi: String?
    let title: String?
    let publication_date: String?
    let primary_location: Location?
    let authorships: [Authorship]?
    let cited_by_count: Int?
    let abstract_inverted_index: [String: [Int]]?
    let ids: IDs?
    let topics: [Topic]?
    let type: String?
    let open_access: OpenAccess?
    let language: String?

    struct Location: Decodable { let source: Source? }
    struct Source: Decodable { let id: String?; let display_name: String?; let type: String? }
    struct Authorship: Decodable { let author: Author?; let institutions: [Institution]? }
    struct Institution: Decodable { let display_name: String? }
    struct Author: Decodable { let id: String?; let display_name: String? }
    struct IDs: Decodable { let pmid: String? }
    struct Topic: Decodable { let id: String?; let display_name: String? }
    struct OpenAccess: Decodable { let is_oa: Bool? }

    /// A record with no title or date cannot be shown on a card.
    var paper: Paper? {
        guard let title, !title.isEmpty, let publication_date else { return nil }
        let source = primary_location?.source
        return Paper(
            id: Identifiers.openAlexID(id),
            doi: Identifiers.doi(doi),
            pmid: Identifiers.pmid(ids?.pmid),
            title: title,
            abstract: Abstract.rebuild(abstract_inverted_index),
            journal: source?.display_name,
            isRepository: source?.type == "repository",
            openAlexType: type,
            sourceType: source?.type,
            date: publication_date,
            authors: (authorships ?? []).compactMap { $0.author?.display_name },
            authorIDs: (authorships ?? []).compactMap { $0.author?.id }.map(Identifiers.openAlexID),
            firstInstitution: authorships?.first?.institutions?.first?.display_name,
            lastInstitution: authorships?.last?.institutions?.first?.display_name,
            citedBy: cited_by_count ?? 0,
            topics: (topics ?? []).compactMap(\.display_name),
            topicIDs: (topics ?? []).compactMap(\.id).map(Identifiers.openAlexID),
            journalID: source?.id.map(Identifiers.openAlexID),
            isOpenAccess: open_access?.is_oa ?? false,
            language: language
        )
    }
}
