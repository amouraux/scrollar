import Foundation

/// A file the user can keep, e-mail to themselves or move to a new phone: the settings as they
/// are now. It is a different thing from the sync file, which merges two devices and holds what
/// was decided and when; this is a snapshot that replaces what is there when restored.
///
/// It never holds the OpenAlex key (that is a credential, and stays in the Keychain), the feed
/// (a cache that rebuilds) or which papers were read (a record of use, not a setting).
struct SettingsBackup: Codable {
    static let currentFormat = 1

    var app = "Scrollar"
    var format = SettingsBackup.currentFormat
    var savedAt: Date
    var settings: FeedSettings
}

enum Backup {
    static func encode(_ settings: FeedSettings, at date: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(SettingsBackup(savedAt: date, settings: settings))
    }

    enum Outcome: Equatable {
        case settings(FeedSettings, savedAt: Date?)
        /// Written by a newer app: restoring it would drop what this one does not know.
        case newerFormat
        /// Anything else, so a wrong file (the sync file, a photo renamed) is refused instead of
        /// replacing the settings with defaults, which is what decoding it leniently would do.
        case notABackup
    }

    static func decode(_ data: Data) -> Outcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["app"] as? String == "Scrollar", object["settings"] is [String: Any] else { return .notABackup }
        if let format = object["format"] as? Int, format > SettingsBackup.currentFormat { return .newerFormat }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(SettingsBackup.self, from: data) else { return .notABackup }
        if backup.settings.formatVersion > FeedSettings.currentFormat { return .newerFormat }
        return .settings(backup.settings, savedAt: backup.savedAt)
    }

    /// "Scrollar settings 2026-11-08", which sorts by date in a folder of them.
    static func filename(at date: Date) -> String { "Scrollar settings " + Ranker.dayString(date) }

    /// What a backup holds, in words, so the reader can see what restoring would put in place.
    static func summary(of s: FeedSettings) -> [String] {
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) " + (n == 1 ? one : many) }
        return [
            count(s.followedTopics.count, "topic", "topics"),
            count(s.followedJournals.count, "journal", "journals"),
            count(s.followedAuthors.count, "researcher", "researchers"),
            count(s.followedInstitutions.count, "institution", "institutions"),
            count(s.followedFunders.count, "funder", "funders"),
            count(s.followedKeywords.count, "keyword", "keywords"),
            count(s.mutedJournals.count + s.mutedAuthors.count + s.mutedTopics.count + s.mutedKeywords.count, "mute", "mutes"),
            count(s.feedback.saved.count, "saved paper", "saved papers"),
            count(s.feedback.liked.count, "paper marked for me", "papers marked for me"),
            count(s.feedback.hidden.count, "hidden paper", "hidden papers"),
        ].compactMap { $0 }
    }
}
