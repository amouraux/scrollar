import Foundation
import Security

/// Credentials live in the Keychain: they are not in the settings file, the feed cache, a backup or
/// the binary. One item per service, so the OpenAlex key and the Zotero key never meet.
enum Keychain {
    private static let openAlex = "com.andremouraux.scrollar.openalex"
    static let zotero = "com.andremouraux.scrollar.zotero"
    static let summaries = "com.andremouraux.scrollar.summaries"
    private static let account = "api-key"

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(service: String = openAlex) -> String {
        var q = query(service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keep a value, and say whether it was kept: it is read back, because a device (a Mac build with
    /// no provisioning profile, say) can refuse an item without anything else going wrong. Saving an
    /// empty value removes the item and counts as kept.
    @discardableResult
    static func save(_ value: String, service: String = openAlex) -> Bool {
        SecItemDelete(query(service) as CFDictionary)
        guard !value.isEmpty else { return true }
        var q = query(service)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        return status == errSecSuccess && load(service: service) == value
    }
}

struct CachedFeed: Codable {
    var citedYou: [RankedPaper]
    var forYou: [RankedPaper]
    var authorName: String?
    var date: Date
    var usedEmbeddings: Bool?
    /// Which on-device text model ranked it. Optional: a cache written before there was a second one.
    var embedderID: String?
    /// The settings (without feedback) this feed was built from. If they differ at
    /// the next launch, the feed is out of date however recent it is.
    var builtWith: FeedSettings?
    /// The last fetch every seed answered covered papers up to here.
    var fetchedThrough: Date?
    /// When the whole look-back window was last fetched from scratch.
    var fullBuildAt: Date?
    /// Days held beyond the look-back.
    var extraDays: Int?
}

/// Files in the app's own container. Settings are kept; the feed and the
/// embedding vectors are a cache that can always be rebuilt.
struct Store {
    private let fm = FileManager.default

    private func folder(_ base: FileManager.SearchPathDirectory) -> URL {
        let dir = fm.urls(for: base, in: .userDomainMask)[0].appendingPathComponent("Scrollar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var settingsURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("settings.json") }
    private var feedURL: URL { folder(.cachesDirectory).appendingPathComponent("feed.json") }
    private var historyURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("history.json") }
    private var ledgerURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("sync-ledger.json") }
    private var summariesURL: URL { folder(.cachesDirectory).appendingPathComponent("summaries.json") }
    private var zoteroURL: URL { folder(.cachesDirectory).appendingPathComponent("zotero.json") }
    private var libraryFileURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("library-import.json") }
    private var projectURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("project.json") }
    private var projectsURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("projects.json") }
    private var searchesURL: URL { folder(.applicationSupportDirectory).appendingPathComponent("searches.json") }
    private var embeddingsURL: URL { folder(.cachesDirectory).appendingPathComponent("embeddings.plist") }

    enum SettingsResult {
        case none
        case loaded(FeedSettings)
        /// The file exists but is not JSON. It is copied aside, never overwritten
        /// in silence: a file that will not load looks exactly like a setting
        /// having no effect.
        case unreadable(keptAs: String)
    }

    func loadSettings() -> SettingsResult {
        guard let data = try? Data(contentsOf: settingsURL) else { return .none }
        do {
            return .loaded(try FeedSettings.decode(data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let copy = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.unreadable-\(stamp).json")
            try? fm.copyItem(at: settingsURL, to: copy)
            return .unreadable(keptAs: copy.lastPathComponent)
        }
    }

    func saveSettings(_ s: FeedSettings) {
        if let data = try? s.encoded() { try? data.write(to: settingsURL, options: .atomic) }
    }

    func loadFeed() -> CachedFeed? {
        guard let data = try? Data(contentsOf: feedURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A cache written by another version simply does not load; it is rebuilt.
        return try? decoder.decode(CachedFeed.self, from: data)
    }

    func saveFeed(_ feed: CachedFeed) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(feed) { try? data.write(to: feedURL, options: .atomic) }
    }

    /// A record of behaviour, not something the user entered: if it cannot be
    /// read the feed starts again from "everything is new", which costs little.
    func loadHistory() -> History {
        guard let data = try? Data(contentsOf: historyURL) else { return History() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(History.self, from: data)) ?? History()
    }

    func saveHistory(_ history: History) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
    }

    /// Takeaways the on-device model wrote, by paper. Regenerable, so a cache.
    func loadSummaries() -> [String: String] {
        guard let data = try? Data(contentsOf: summariesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func saveSummaries(_ summaries: [String: String]) {
        if let data = try? JSONEncoder().encode(summaries) { try? data.write(to: summariesURL, options: .atomic) }
    }

    /// When the settings were last written: the best guess at when the user last changed
    /// anything, which a first sync stamps the existing settings with.
    var settingsModified: Date? {
        (try? fm.attributesOfItem(atPath: settingsURL.path))?[.modificationDate] as? Date
    }

    /// What this device has decided, and when, for syncing. Without it a restart would
    /// forget which changes were made here and which came from elsewhere.
    func loadLedger() -> SyncDocument? {
        guard let data = try? Data(contentsOf: ledgerURL), case .document(let doc) = SyncDocument.read(data) else { return nil }
        return doc
    }

    func saveLedger(_ ledger: SyncDocument) {
        if let data = try? ledger.encoded() { try? data.write(to: ledgerURL, options: .atomic) }
    }

    /// What was last read of the user's Zotero library. A cache: it is read again when Zotero says it changed.
    func loadZotero() -> ZoteroCache? {
        guard let data = try? Data(contentsOf: zoteroURL) else { return nil }
        return try? JSONDecoder().decode(ZoteroCache.self, from: data)
    }

    func saveZotero(_ cache: ZoteroCache?) {
        guard let cache, let data = try? JSONEncoder().encode(cache) else { try? fm.removeItem(at: zoteroURL); return }
        try? data.write(to: zoteroURL, options: .atomic)
    }

    /// The last RIS or BibTeX export imported. In Application Support, not the caches: it cannot be
    /// fetched again, and when each item first appeared is only known from having seen it.
    func loadLibraryFile() -> LibraryFile? {
        guard let data = try? Data(contentsOf: libraryFileURL) else { return nil }
        return try? JSONDecoder().decode(LibraryFile.self, from: data)
    }

    func saveLibraryFile(_ file: LibraryFile?) {
        guard let file, let data = try? JSONEncoder().encode(file) else { try? fm.removeItem(at: libraryFileURL); return }
        try? data.write(to: libraryFileURL, options: .atomic)
    }

    /// The project description the user pasted. Application Support, for the same reason as the
    /// library file: it cannot be fetched again. Never synced: it may be a confidential proposal.
    func loadProjects() -> [ProjectFile] {
        if let data = try? Data(contentsOf: projectsURL) { return ProjectFile.decodeList(data) }
        // The single project an earlier version kept moves to the list, once.
        guard let data = try? Data(contentsOf: projectURL) else { return [] }
        let list = ProjectFile.decodeList(data)
        saveProjects(list)
        try? fm.removeItem(at: projectURL)
        return list
    }

    func saveProjects(_ projects: [ProjectFile]) {
        guard !projects.isEmpty, let data = try? JSONEncoder().encode(projects) else { try? fm.removeItem(at: projectsURL); return }
        try? data.write(to: projectsURL, options: .atomic)
    }

    /// What was searched for, newest first. On this device only, and not synced: what someone searches for says
    /// what they are working on.
    func loadSearches() -> [Search] {
        (try? Data(contentsOf: searchesURL)).flatMap { try? JSONDecoder().decode([Search].self, from: $0) } ?? []
    }

    func saveSearches(_ searches: [Search]) {
        guard !searches.isEmpty, let data = try? JSONEncoder().encode(searches) else { try? fm.removeItem(at: searchesURL); return }
        try? data.write(to: searchesURL, options: .atomic)
    }

    func loadEmbeddings() -> Data? { try? Data(contentsOf: embeddingsURL) }

    func saveEmbeddings(_ data: Data) { try? data.write(to: embeddingsURL, options: .atomic) }
}
