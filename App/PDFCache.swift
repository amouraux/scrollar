import Foundation
import CryptoKit

/// PDFs fetched for the reader, kept on this device so a paper opened again (or sent to a reference
/// manager) does not download again, and can be read offline. In the Caches folder: the system may
/// empty it when space is short and nothing is lost but a download, and it is not backed up.
/// Capped by a size the user chooses, least recently used out first (the rule is `PDFCachePlan`).
enum PDFCache {
    /// The dedupeKeys of papers the user saved or marked For me, whose PDFs are the last to go and
    /// the ones that go to the shared folder. Set by the model.
    nonisolated(unsafe) static var savedKeys: () -> [String] = { [] }

    private static let limitKey = "pdfCacheLimit"
    private static let largest = 80_000_000

    /// Bytes, or nil for no limit.
    static var limit: Int? {
        get {
            guard let v = UserDefaults.standard.object(forKey: limitKey) as? Int else { return PDFCachePlan.defaultLimit }
            return v < 0 ? nil : v
        }
        set { UserDefaults.standard.set(newValue ?? -1, forKey: limitKey) }
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A name that cannot clash or hold a character a file system dislikes.
    static func name(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".pdf"
    }

    /// The file for a paper, if one was kept. Looking counts as use, so it is the last to be trimmed.
    static func lookup(_ key: String) -> URL? {
        let url = folder.appendingPathComponent(name(for: key))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    static func store(_ data: Data, key: String) -> URL? {
        let url = folder.appendingPathComponent(name(for: key))
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        trim()
        return url
    }

    private static func entries() -> [PDFCachePlan.Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { f in
            guard f.pathExtension == "pdf", let v = try? f.resourceValues(forKeys: Set(keys)) else { return nil }
            return PDFCachePlan.Entry(name: f.lastPathComponent, size: v.fileSize ?? 0, used: v.contentModificationDate ?? .distantPast)
        }
    }

    static func usage() -> (count: Int, bytes: Int) {
        let e = entries()
        return (e.count, PDFCachePlan.total(e))
    }

    /// Delete what no longer fits the limit.
    static func trim() {
        guard let limit else { return }
        let protected = Set(savedKeys().map(name(for:)))
        for gone in PDFCachePlan.eviction(entries(), limit: limit, protected: protected) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(gone))
        }
    }

    /// Empty the cache, or everything except the PDFs of saved papers.
    static func clear(keepingSaved: Bool) {
        let keep = keepingSaved ? Set(savedKeys().map(name(for:))) : []
        for e in entries() where !keep.contains(e.name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(e.name))
        }
    }

    // MARK: Fetching

    enum Fetch {
        case pdf(Data)
        /// The site answered, but not with a PDF; `why` says what it did say.
        case refused(why: String)
        case offline
        case failed
    }

    /// Publishers commonly answer a bare `CFNetwork` request with 403 or a 500 while serving the
    /// same file to a browser, so the request looks like one: a browser's User-Agent, and the
    /// paper's own page as the referrer, which is where a reader would have clicked from.
    private static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// The plain download: the first approach, before a web view is tried.
    static func fetch(_ url: URL, referer: URL?) async -> Fetch {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/pdf,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        do {
            var (file, response) = try await URLSession.shared.download(for: request)
            // A 5xx from a publisher is often a momentary refusal of a first request: ask once more.
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                try? await Task.sleep(for: .seconds(1))
                (file, response) = try await URLSession.shared.download(for: request)
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Files this large are left to the browser: they would be held in memory in full.
            guard size <= largest else { return .refused(why: "This PDF is too large to download here.") }
            let data = try Data(contentsOf: file)
            guard data.prefix(5) == Data("%PDF-".utf8) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .refused(why: status >= 400 ? "The site refused a direct download (error \(status))."
                                                   : "The site sent a web page, not a PDF.")
            }
            return .pdf(data)
        } catch {
            // A dropped connection is not the site's refusal: a web view would fail the same way.
            return (error as? URLError)?.code == .notConnectedToInternet ? .offline : .failed
        }
    }

    /// The kept copy, or the one in the folder shared between devices, brought here. Nil when neither
    /// exists. The folder is read off the main thread: it may be waiting on iCloud.
    static func lookupAnywhere(_ key: String) async -> URL? {
        if let local = lookup(key) { return local }
        return await Task.detached { PDFFolder.bring(key) }.value
    }

    /// Hand a PDF to the shared folder when the user has one and the policy wants this paper in it.
    static func shareWithDevices(_ local: URL, key: String, stem: String) {
        guard PDFFolder.url != nil else { return }
        Task.detached { PDFFolder.offer(local, key: key, stem: stem) }
    }

    /// The paper's PDF on disk: the kept copy, or a direct download that is then kept. Nil when the
    /// site does not hand it over (the reader's web view may still show it).
    static func file(for key: String, url: URL, referer: URL?, stem: String = "paper") async -> URL? {
        if let kept = await lookupAnywhere(key) { return kept }
        guard case .pdf(let data) = await fetch(url, referer: referer), let stored = store(data, key: key) else { return nil }
        shareWithDevices(stored, key: key, stem: stem)
        return stored
    }

    // MARK: Handing a file on

    static func md5(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A copy under a name a person would recognise, for a share sheet or an import: the cache's
    /// own names are hashes.
    static func namedCopy(_ cached: URL, as name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: cached, to: target)
            return target
        } catch { return nil }
    }
}
