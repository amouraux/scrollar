import Foundation
import Security

/// The OpenAlex key lives in the Keychain: it is a credential, so it is not in
/// the settings file, the feed cache, a backup or the binary.
enum Keychain {
    private static let service = "com.andremouraux.scrollar.openalex"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

struct CachedFeed: Codable {
    var citedYou: [RankedPaper]
    var forYou: [RankedPaper]
    var authorName: String?
    var date: Date
    var usedEmbeddings: Bool?
    /// The settings (without feedback) this feed was built from. If they differ at
    /// the next launch, the feed is out of date however recent it is.
    var builtWith: FeedSettings?
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

    func loadEmbeddings() -> Data? { try? Data(contentsOf: embeddingsURL) }

    func saveEmbeddings(_ data: Data) { try? data.write(to: embeddingsURL, options: .atomic) }
}
