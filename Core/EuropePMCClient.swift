import Foundation

/// Europe PMC's REST search: no key, and it covers PubMed and MEDLINE records, the
/// preprint servers and more. Only this file and OrcidClient reach the network
/// for these two sources.
struct EuropePMCClient {
    var session: URLSession = .shared
    private let base = "https://www.ebi.ac.uk/europepmc/webservices/rest/"

    /// One retry, a second later, for what is usually momentary: a timeout or a 5xx.
    /// Europe PMC is free and sometimes slow; a feed should not fail on one hiccup,
    /// nor hammer a service that is down.
    private func fetch(_ endpoint: String, _ query: [String: String]) async throws -> Data {
        guard var comps = URLComponents(string: base + endpoint) else { throw OpenAlexError.notFound(endpoint) }
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw OpenAlexError.notFound(endpoint) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        var lastError: Error = OpenAlexError.notFound(endpoint)
        for attempt in 0..<2 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                lastError = OpenAlexError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
                if status < 500 { throw lastError }
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                lastError = error
            }
        }
        throw lastError
    }

    /// The papers matching a query, newest first, up to `maxPages` of a hundred.
    func papers(query: String, maxPages: Int) async throws -> [Paper] {
        var found: [Paper] = []
        for page in 1...max(maxPages, 1) {
            let data = try await fetch("search", [
                "query": query, "format": "json", "resultType": "core",
                "pageSize": "100", "page": String(page), "sort": "P_PDATE_D desc",
            ])
            let batch = EuropePMCParser.papers(from: data)
            found += batch
            if EuropePMCParser.hitCount(in: data) <= page * 100 || batch.isEmpty { break }
        }
        return found
    }

    /// The records for these DOIs, a few to a request (a long query is refused), three
    /// requests at a time. A request that still fails costs only its own papers.
    func papers(dois: [String]) async throws -> [Paper] {
        let chunks = stride(from: 0, to: dois.count, by: 12).map { Array(dois[$0..<min($0 + 12, dois.count)]) }
        var found: [Paper] = []
        for start in stride(from: 0, to: chunks.count, by: 3) {
            let wave = chunks[start..<min(start + 3, chunks.count)]
            await withTaskGroup(of: [Paper].self) { group in
                for chunk in wave {
                    group.addTask {
                        let query = chunk.map { "DOI:\"\($0)\"" }.joined(separator: " OR ")
                        guard let data = try? await self.fetch("search", ["query": query, "format": "json",
                                                                          "resultType": "core", "pageSize": "100"]) else { return [] }
                        return EuropePMCParser.papers(from: data)
                    }
                }
                for await papers in group { found += papers }
            }
        }
        return found
    }
}

/// ORCID's public API: a person's name and the works they list. No key.
struct OrcidClient {
    var session: URLSession = .shared

    private func fetch(_ path: String) async throws -> Data {
        guard let url = URL(string: "https://pub.orcid.org/v3.0/" + path) else { throw OpenAlexError.notFound(path) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw OpenAlexError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        return data
    }

    func name(orcid: String) async throws -> String? {
        OrcidParser.name(from: try await fetch("\(orcid)/person"))
    }

    func works(orcid: String) async throws -> [OrcidWork] {
        OrcidParser.works(from: try await fetch("\(orcid)/works"))
    }
}
