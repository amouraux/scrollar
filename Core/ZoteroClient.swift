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
    case storageFull
    case failed(String)

    var description: String {
        switch self {
        case .refused: return "Zotero refused the key. Check that it is right and has not been deleted."
        case .slowDown(let seconds): return "Zotero asked to wait" + (seconds.map { " \($0) seconds" } ?? "") + " before the next request."
        case .server(let code): return "Zotero answered with an error (\(code))."
        case .unreadable: return "Zotero's answer could not be read."
        case .cannotWrite: return "This key can only read your library. Make one that may also write, to save papers here."
        case .storageFull: return "Your Zotero file storage is full."
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

    /// A PDF on this device to put with the item, and its MD5, which Zotero asks for. The hash is
    /// the caller's because Foundation has none.
    struct PDF {
        var file: URL
        var md5: String
    }

    /// What saving did: the item's key, and how the PDF went. The item is the point; a PDF that
    /// could not be attached (storage full, too large) never makes the save fail.
    struct Added: Equatable {
        var key: String
        var pdf: PDFOutcome
    }

    enum PDFOutcome: Equatable {
        case notOffered, attached
        case skipped(String)
    }

    /// Largest file sent in one piece; bigger ones are left for the reader to attach in Zotero.
    static let largestPDF = 40_000_000

    /// Adds a paper to a collection (or the library's top level), with its PDF when there is one.
    /// The write token makes a retry of the same request safe: Zotero ignores a token it has
    /// already seen.
    @discardableResult
    func add(_ reference: RIS.Reference, collection: String? = nil, pdf: PDF? = nil) async throws -> Added {
        guard account.canWrite else { throw ZoteroError.cannotWrite }
        let data = try await write("/users/\(account.userID)/items", Zotero.newItems(reference, collection: collection))
        if let why = Zotero.writeFailure(from: data) { throw ZoteroError.failed(why) }
        guard let key = Zotero.createdKey(from: data) else { return Added(key: "", pdf: .notOffered) }
        guard let pdf else { return Added(key: key, pdf: .notOffered) }
        do {
            try await attach(pdf, to: key)
            return Added(key: key, pdf: .attached)
        } catch ZoteroError.storageFull {
            return Added(key: key, pdf: .skipped("Your Zotero file storage is full, so the PDF was not attached."))
        } catch {
            return Added(key: key, pdf: .skipped("The PDF could not be attached (\(error))."))
        }
    }

    private func write(_ path: String, _ body: Data) async throws -> Data {
        var r = request(path)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.token(), forHTTPHeaderField: "Zotero-Write-Token")
        r.httpBody = body
        let (data, response) = try await session.data(for: r)
        _ = try Self.check(response)
        return data
    }

    private static func token() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// The three steps Zotero's file upload takes: make the attachment item, ask where to send the
    /// file, send it and say it arrived.
    private func attach(_ pdf: PDF, to parent: String) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: pdf.file.path)[.size] as? Int) ?? 0
        guard size > 0, size <= Self.largestPDF else { throw ZoteroError.failed("the file is too large to send from here") }
        let filename = "paper.pdf"
        let made = try await write("/users/\(account.userID)/items", Zotero.pdfAttachment(parent: parent, filename: filename))
        if let why = Zotero.writeFailure(from: made) { throw ZoteroError.failed(why) }
        guard let item = Zotero.createdKey(from: made) else { throw ZoteroError.unreadable }

        var ask = request("/users/\(account.userID)/items/\(item)/file")
        ask.httpMethod = "POST"
        ask.setValue("*", forHTTPHeaderField: "If-None-Match")
        ask.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let mtime = Int((try? pdf.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000
        ask.httpBody = Data("md5=\(pdf.md5)&filename=\(filename)&filesize=\(size)&mtime=\(mtime)".utf8)
        let (answer, askResponse) = try await session.data(for: ask)
        do { _ = try Self.check(askResponse) } catch ZoteroError.server(413) { throw ZoteroError.storageFull }
        switch Zotero.uploadAnswer(from: answer) {
        case .exists: return
        case .none: throw ZoteroError.unreadable
        case .send(let url, let type, let prefix, let suffix, let uploadKey)?:
            var upload = URLRequest(url: url, timeoutInterval: 120)
            upload.httpMethod = "POST"
            upload.setValue(type, forHTTPHeaderField: "Content-Type")
            upload.httpBody = Data(prefix.utf8) + (try Data(contentsOf: pdf.file)) + Data(suffix.utf8)
            let (_, sent) = try await session.data(for: upload)
            guard let http = sent as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ZoteroError.server((sent as? HTTPURLResponse)?.statusCode ?? 0) }
            var done = request("/users/\(account.userID)/items/\(item)/file")
            done.httpMethod = "POST"
            done.setValue("*", forHTTPHeaderField: "If-None-Match")
            done.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            done.httpBody = Data("upload=\(uploadKey)".utf8)
            let (_, registered) = try await session.data(for: done)
            _ = try Self.check(registered)
        }
    }

    /// The library's top-level collections.
    func collections() async throws -> [Zotero.Collection] {
        let (data, response) = try await session.data(for: request("/users/\(account.userID)/collections", query: ["format": "json", "limit": "100"]))
        _ = try Self.check(response)
        return Zotero.collections(from: data)
    }

    func createCollection(named name: String) async throws -> Zotero.Collection {
        guard account.canWrite else { throw ZoteroError.cannotWrite }
        let data = try await write("/users/\(account.userID)/collections", Zotero.newCollection(name))
        if let why = Zotero.writeFailure(from: data) { throw ZoteroError.failed(why) }
        guard let key = Zotero.createdKey(from: data) else { throw ZoteroError.unreadable }
        return Zotero.Collection(key: key, name: name)
    }
}
