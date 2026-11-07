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

    func works(filter: String, perPage: Int, sort: String = "publication_date:desc") async throws -> [Paper] {
        let data = try await fetch("works", [
            "filter": filter,
            "per-page": String(perPage),
            "sort": sort,
            "select": Self.workFields,
        ])
        return try JSONDecoder().decode(WorksDTO.self, from: data).results.compactMap(\.paper)
    }

    /// Run one seed, tagging every result with why it is there.
    func papers(for seed: Seed, since: String, perPage: Int = 100) async throws -> [Paper] {
        var found = try await works(filter: seed.filter(since: since), perPage: perPage)
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
    struct Authorship: Decodable { let author: Author? }
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
            citedBy: cited_by_count ?? 0,
            topics: (topics ?? []).compactMap(\.display_name),
            topicIDs: (topics ?? []).compactMap(\.id).map(Identifiers.openAlexID),
            journalID: source?.id.map(Identifiers.openAlexID),
            isOpenAccess: open_access?.is_oa ?? false,
            language: language
        )
    }
}
