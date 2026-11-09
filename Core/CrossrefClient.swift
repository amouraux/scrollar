import Foundation

/// What a request to a free service should say about who is asking, and how it survives a hiccup:
/// one retry, a second later, for a timeout or a 5xx, and a wait for as long as the service asks (at
/// most ten seconds) on "too many requests". A refusal or a missing answer is not retried.
enum PoliteFetch {
    static let agent = "Scrollar/0.1 (+https://amouraux.github.io/scrollar/)"

    static func data(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        var lastError: Error = OpenAlexError.notFound(url.host ?? "")
        var pause: UInt64 = 1_000_000_000
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: pause) }
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 200 { return data }
                lastError = OpenAlexError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
                if status == 429 {
                    let asked = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
                    pause = UInt64(min(max(asked, 1), 10) * 1_000_000_000)
                    continue
                }
                if status < 500 { throw lastError }
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                lastError = error
            }
        }
        throw lastError
    }
}

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
            let data = try await PoliteFetch.data(url, session: session)
            found += CrossrefParser.papers(from: data, seed: seed)
            if CrossrefParser.total(in: data) <= (page + 1) * 100 { break }
        }
        return found
    }
}
