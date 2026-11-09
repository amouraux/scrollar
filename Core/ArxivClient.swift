import Foundation

struct ArxivClient {
    var session: URLSession = .shared
    /// arXiv's terms: no more than one request in three seconds, from everywhere in the app.
    static let gate = RequestGate(interval: 3)

    /// The newest papers for a seed in the window, up to `maxPages` of a hundred.
    func papers(seed: Seed, since: String, until: String, maxPages: Int) async throws -> [Paper] {
        var found: [Paper] = []
        for page in 0..<max(maxPages, 1) {
            guard let items = ArxivQuery.build(seed, since: since, until: until, start: page * 100),
                  var comps = URLComponents(string: "https://export.arxiv.org/api/query") else { return found }
            comps.queryItems = items
            guard let url = comps.url else { return found }
            await Self.gate.wait()
            let data = try await PoliteFetch.data(url, session: session)
            let batch = ArxivParser.papers(from: data, seed: seed)
            found += batch
            // A full page of entries (before the name check) means there may be more.
            if ArxivParser.entryCount(in: data) < 100 { break }
        }
        return found
    }
}
