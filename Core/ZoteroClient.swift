import Foundation

/// What was read of the library, and as of which library version, so the next read can ask
/// "anything new since?" and get an empty answer when there is nothing.
struct ZoteroCache: Codable, Equatable {
    var userID: Int
    var version: Int
    /// How many items were asked for; a cache that holds fewer than are wanted now is not enough.
    var asked: Int
    var items: [LibraryItem]
}

enum ZoteroError: Error, CustomStringConvertible {
    case refused
    case slowDown(Int?)
    case server(Int)
    case unreadable
    case cannotWrite
    case failed(String)

    var description: String {
        switch self {
        case .refused: return "Zotero refused the key. Check that it is right and has not been deleted."
        case .slowDown(let seconds): return "Zotero asked to wait" + (seconds.map { " \($0) seconds" } ?? "") + " before the next request."
        case .server(let code): return "Zotero answered with an error (\(code))."
        case .unreadable: return "Zotero's answer could not be read."
        case .cannotWrite: return "This key can only read your library. Make one that may also write, to save papers here."
        case .failed(let why): return "Zotero did not add it: \(why)"
        }
    }
}

/// The only file that talks to Zotero. The key goes in a header and is never part of an error
/// message or a log line.
struct ZoteroClient {
    var account: ZoteroAccount
    var session: URLSession = .shared

    private static let base = "https://api.zotero.org"

    private func request(_ path: String, query: [String: String] = [:], key: String? = nil) -> URLRequest {
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: comps.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
        r.setValue(key ?? account.key, forHTTPHeaderField: "Zotero-API-Key")
        return r
    }

    private static func check(_ response: URLResponse?) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ZoteroError.unreadable }
        switch http.statusCode {
        case 200..<300, 304: return http
        case 401, 403: throw ZoteroError.refused
        case 429, 503: throw ZoteroError.slowDown(Int(http.value(forHTTPHeaderField: "Retry-After") ?? ""))
        default: throw ZoteroError.server(http.statusCode)
        }
    }

    /// Whose key this is and what it may do. The only call that needs no account.
    static func connect(key: String, session: URLSession = .shared) async throws -> ZoteroAccount {
        let probe = ZoteroClient(account: ZoteroAccount(key: key, userID: 0, username: "", canWrite: false), session: session)
        let (data, response) = try await session.data(for: probe.request("/keys/current"))
        _ = try check(response)
        guard let account = Zotero.account(key: key, from: data) else { throw ZoteroError.unreadable }
        return account
    }

    /// The `limit` most recently added items. With a `cache` of the same library that is still
    /// current, Zotero answers "not modified" and nothing is downloaded again.
    func recent(limit: Int, cache: ZoteroCache?) async throws -> ZoteroCache {
        let usable = cache.flatMap { $0.userID == account.userID && $0.asked >= limit ? $0 : nil }
        var items: [LibraryItem] = []
        var version = 0
        var start = 0
        while start < limit {
            var r = request("/users/\(account.userID)/items", query: [
                "format": "json", "sort": "dateAdded", "direction": "desc", "itemType": "-attachment",
                "limit": String(min(100, limit - start)), "start": String(start),
            ])
            if start == 0, let usable { r.setValue(String(usable.version), forHTTPHeaderField: "If-Modified-Since-Version") }
            let (data, response) = try await session.data(for: r)
            let http = try Self.check(response)
            if http.statusCode == 304, let usable { return usable }
            version = Int(http.value(forHTTPHeaderField: "Last-Modified-Version") ?? "") ?? version
            let page = Zotero.items(from: data)
            items += page
            // A short page, counting what was filtered out, is the end of the library.
            let rawCount = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
            if rawCount < min(100, limit - start) { break }
            start += rawCount
        }
        return ZoteroCache(userID: account.userID, version: version, asked: limit, items: items)
    }

    /// Whether the library already holds a paper with this DOI, so saving twice does not make two.
    func has(doi: String) async throws -> Bool {
        let (data, response) = try await session.data(for: request("/users/\(account.userID)/items", query: [
            "format": "json", "q": doi, "qmode": "everything", "limit": "5", "itemType": "-attachment",
        ]))
        _ = try Self.check(response)
        return Zotero.items(from: data).contains { $0.doi == Identifiers.doi(doi) }
    }

    /// Adds a paper to the library's top level. The write token makes a retry of the same request
    /// safe: Zotero ignores a token it has already seen.
    func add(_ reference: RIS.Reference) async throws {
        guard account.canWrite else { throw ZoteroError.cannotWrite }
        var r = request("/users/\(account.userID)/items")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), forHTTPHeaderField: "Zotero-Write-Token")
        r.httpBody = Zotero.newItems(reference)
        let (data, response) = try await session.data(for: r)
        _ = try Self.check(response)
        if let why = Zotero.writeFailure(from: data) { throw ZoteroError.failed(why) }
    }
}
