import Foundation

/// NCBI E-utilities. No key: the limit is three requests a second, so every
/// call waits a little first rather than being refused part-way through a feed.
struct PubMedClient {
    var session: URLSession = .shared
    private let base = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
    private let pause: UInt64 = 400_000_000

    private func fetch(_ endpoint: String, _ query: [String: String]) async throws -> Data {
        try await Task.sleep(nanoseconds: pause)
        guard var comps = URLComponents(string: base + endpoint) else { throw SourceError.notFound(source: "PubMed", what: endpoint) }
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "tool", value: "scrollar"))
        comps.queryItems = items
        guard let url = comps.url else { throw SourceError.notFound(source: "PubMed", what: endpoint) }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SourceError.http(source: "PubMed", status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// Abstracts and publication types for these PMIDs, 100 to a request.
    func records(pmids: [String]) async throws -> [PubMedRecord] {
        var all: [PubMedRecord] = []
        let unique = Array(Set(pmids)).sorted()
        for start in stride(from: 0, to: unique.count, by: 100) {
            let chunk = unique[start..<min(start + 100, unique.count)]
            let data = try await fetch("efetch.fcgi", [
                "db": "pubmed", "id": chunk.joined(separator: ","), "retmode": "xml",
            ])
            all += PubMedParser.parse(data)
        }
        return all
    }

    /// The PMID for a DOI, or nil when PubMed does not have exactly one match.
    func pmid(forDOI doi: String) async throws -> String? {
        let data = try await fetch("esearch.fcgi", [
            "db": "pubmed", "term": "\"\(doi)\"[AID]", "retmode": "json", "retmax": "2",
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["esearchresult"] as? [String: Any],
              let ids = result["idlist"] as? [String], ids.count == 1 else { return nil }
        return ids[0]
    }
}
