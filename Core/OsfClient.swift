import Foundation

struct OsfClient {
    var session: URLSession = .shared
    /// A request a second, from everywhere in the app: OSF's limits are generous and this keeps well inside them.
    static let gate = RequestGate(interval: 1)

    /// The newest preprints for a seed in the window, up to `maxPages` of fifty.
    func papers(seed: Seed, since: String, until: String, maxPages: Int) async throws -> [Paper] {
        var found: [Paper] = []
        for page in 1...max(maxPages, 1) {
            guard let items = OsfQuery.build(seed, since: since, until: until, page: page),
                  var comps = URLComponents(string: OsfQuery.base) else { return found }
            comps.queryItems = items
            guard let url = comps.url else { return found }
            await Self.gate.wait()
            let data = try await PoliteFetch.data(url, session: session)
            found += OsfParser.papers(from: data, seed: seed)
            if !OsfParser.hasNext(in: data) { break }
        }
        return found
    }
}
