import Foundation

struct CrossrefClient {
    var session: URLSession = .shared
    /// Crossref's public pool allows a few requests a second; one a second is well inside it, from everywhere in the app.
    static let gate = RequestGate(interval: 1)

    /// The newest papers for a seed in the window, up to `maxPages` of a hundred.
    func papers(seed: Seed, since: String, until: String, maxPages: Int) async throws -> [Paper] {
        var found: [Paper] = []
        for page in 0..<max(maxPages, 1) {
            guard let items = CrossrefQuery.build(seed, since: since, until: until, offset: page * 100),
                  var comps = URLComponents(string: "https://api.crossref.org/works") else { return found }
            comps.queryItems = items
            guard let url = comps.url else { return found }
            await Self.gate.wait()
            let data = try await PoliteFetch.data(url, source: SourceKind.crossref.rawValue, session: session)
            found += CrossrefParser.papers(from: data, seed: seed)
            if CrossrefParser.total(in: data) <= (page + 1) * 100 { break }
        }
        return found
    }
}
