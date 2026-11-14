import Foundation

/// A source that answered with an error, or could not be asked. Every client uses it, with its own name,
/// so a failure says which service it was: Europe PMC's used to be reported as OpenAlex's.
enum SourceError: Error, CustomStringConvertible {
    case http(source: String, status: Int, body: String)
    case notFound(source: String, what: String)

    var description: String {
        switch self {
        case .http(let source, let code, let body): return "\(source) answered HTTP \(code): \(body.prefix(200))"
        case .notFound(let source, let what): return "\(source) has no record of \(what)"
        }
    }
}

/// Every request to a paper source goes through here, so each says who is asking, gives up after
/// 30 seconds and survives a hiccup the same way: up to two retries, a second apart, for a timeout or
/// a 5xx, and a wait for as long as the service asks (at most ten seconds) on "too many requests".
/// A refusal or a missing answer is not retried. Zotero has its own rules and its own client.
enum PoliteFetch {
    static let agent = "Scrollar/0.1 (+https://amouraux.github.io/scrollar/)"

    static func data(_ url: URL, source: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        var lastError: Error = SourceError.notFound(source: source, what: url.host ?? "")
        var pause: UInt64 = 1_000_000_000
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: pause) }
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 200 { return data }
                lastError = SourceError.http(source: source, status: status, body: String(decoding: data.prefix(200), as: UTF8.self))
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
