import Foundation

// Keeping two devices in step through one JSON file in iCloud Drive. Foundation
// only, so it is tested without a cloud: the file handling is in App/SyncFile.swift.
//
// The unit is one decision the user made: "follow this journal", "save this
// paper", "daily window = 14". Each is an entry with the time of the last change
// to it, and whether it is still there (a removal is kept as a tombstone, or the
// other device would simply put it back). Two files merge entry by entry, the later
// change winning, so editing different things on two devices never conflicts and
// editing the same thing keeps the later edit. What was seen and read only moves
// forward, so it merges without conflicts at all.

struct SyncEntry: Codable, Equatable {
    var at: Date
    /// False for a removal.
    var present: Bool
    /// The item or setting as JSON; nil for a removal or an item that is only its name.
    var value: String?

    /// The later of two decisions. A tie, which only simultaneous edits to the very
    /// same thing can produce, is settled by a fixed rule so both devices pick alike.
    static func later(_ a: SyncEntry, _ b: SyncEntry) -> SyncEntry {
        if a.at != b.at { return a.at > b.at ? a : b }
        if a.present != b.present { return a.present ? a : b }
        return (a.value ?? "") >= (b.value ?? "") ? a : b
    }
}

struct SyncDocument: Codable, Equatable {
    /// Raise for any change an older app would misread, and never remove the guard
    /// in the storage: an app writes only a format it knows.
    static let currentFormat = 4

    var format = SyncDocument.currentFormat
    var entries: [String: SyncEntry] = [:]
    var history = History()

    init() {}

    enum CodingKeys: String, CodingKey { case format, entries, history }

    /// Every field falls back, so a file written by an older or a newer version still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decodeIfPresent(Int.self, forKey: .format)) ?? SyncDocument.currentFormat
        entries = (try? c.decodeIfPresent([String: SyncEntry].self, forKey: .entries)) ?? [:]
        history = (try? c.decodeIfPresent(History.self, forKey: .history)) ?? History()
    }
}

// MARK: - File form

extension SyncDocument {
    /// Milliseconds, not ISO 8601 seconds: two edits in one second must keep their order.
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    func encoded() throws -> Data { try SyncDocument.encoder.encode(self) }

    enum Reading: Equatable {
        /// A new file, nothing in it yet.
        case empty
        case document(SyncDocument)
        /// Written by a newer version: read nothing from it, write nothing to it.
        case newerFormat(Int)
        /// Not a Scrollar sync file. Never overwritten.
        case unreadable
    }

    static func read(_ data: Data) -> Reading {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .empty }
        guard let doc = try? decoder.decode(SyncDocument.self, from: data),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.contains(where: { ["entries", "format", "history"].contains($0) }) == true
        else { return .unreadable }
        return doc.format > currentFormat ? .newerFormat(doc.format) : .document(doc)
    }
}

// MARK: - Merging

extension SyncDocument {
    func merged(with other: SyncDocument) -> SyncDocument {
        var out = self
        for (key, theirs) in other.entries {
            out.entries[key] = out.entries[key].map { SyncEntry.later($0, theirs) } ?? theirs
        }
        out.history = history.merged(with: other.history)
        out.format = max(format, other.format)
        return out
    }

    static func merging(_ documents: [SyncDocument]) -> SyncDocument {
        documents.dropFirst().reduce(documents.first ?? SyncDocument()) { $0.merged(with: $1) }
    }
}

extension PaperState {
    /// Seen and read only move forward: the first sighting is the earliest, the
    /// last the latest, and a paper read anywhere is read. The count is the larger,
    /// not the sum, so merging the same file twice does not inflate it.
    static func merge(_ a: PaperState, _ b: PaperState) -> PaperState {
        let opened: Date?
        switch (a.opened, b.opened) {
        case let (x?, y?): opened = min(x, y)
        case let (x?, nil): opened = x
        case let (nil, y?): opened = y
        case (nil, nil): opened = nil
        }
        // The snapshot of whichever device read it first; any one if they cannot be told apart.
        var snapshot = a.snapshot ?? b.snapshot
        if let x = a.snapshot, let y = b.snapshot {
            snapshot = (a.opened ?? .distantFuture) < (b.opened ?? .distantFuture) ? x
                : (b.opened ?? .distantFuture) < (a.opened ?? .distantFuture) ? y
                : (x.title >= y.title ? x : y)
        }
        return PaperState(firstSeen: min(a.firstSeen, b.firstSeen), lastSeen: max(a.lastSeen, b.lastSeen),
                          seenCount: max(a.seenCount, b.seenCount), opened: opened, snapshot: snapshot,
                          // The larger, as with the count: each device measured its own time on screen.
                          dwell: [a.dwell, b.dwell].compactMap { $0 }.max())
    }
}

extension History {
    func merged(with other: History) -> History {
        var out = self
        for (key, theirs) in other.states {
            out.states[key] = out.states[key].map { PaperState.merge($0, theirs) } ?? theirs
        }
        return out
    }
}

// MARK: - Settings as entries

enum SyncProjection {
    private static func json<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func value<T: Decodable>(_ text: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private static let entityLists: [(name: String, path: WritableKeyPath<FeedSettings, [Entity]>)] = [
        ("followedTopics", \.followedTopics), ("followedJournals", \.followedJournals),
        ("followedAuthors", \.followedAuthors), ("followedInstitutions", \.followedInstitutions),
        ("followedFunders", \.followedFunders), ("trackedPapers", \.trackedPapers),
        ("mutedJournals", \.mutedJournals), ("mutedAuthors", \.mutedAuthors), ("mutedTopics", \.mutedTopics),
    ]

    private struct Scalar {
        var name: String
        var read: (FeedSettings) -> String
        var write: (inout FeedSettings, String) -> Void
    }

    private static func scalar<T: Codable>(_ name: String, _ path: WritableKeyPath<FeedSettings, T>) -> Scalar {
        Scalar(name: name,
               read: { json($0[keyPath: path]) },
               write: { settings, text in if let v: T = value(text) { settings[keyPath: path] = v } })
    }

    private static let scalars: [Scalar] = [
        scalar("orcid", \.orcid), scalar("useMyPublications", \.useMyPublications),
        scalar("useOpenAlex", \.useOpenAlex), scalar("useEuropePMC", \.useEuropePMC),
        scalar("useCrossref", \.useCrossref), scalar("useArXiv", \.useArXiv), scalar("useOSF", \.useOSF), scalar("referenceManagers", \.referenceManagers),
        scalar("kindWeights", \.kindWeights), scalar("daysBack", \.daysBack),
        scalar("recency", \.recency), scalar("closeness", \.closeness),
        scalar("impactWeight", \.impactWeight), scalar("authorWeight", \.authorWeight),
        scalar("byline", \.byline), scalar("requireAbstract", \.requireAbstract),
        scalar("openAccessOnly", \.openAccessOnly), scalar("seenExpiryDays", \.seenExpiryDays),
        scalar("showReadPapers", \.showReadPapers), scalar("languages", \.languages),
        scalar("feedOrder", \.feedOrder), scalar("highlightCount", \.highlightCount),
        scalar("highlightCloseness", \.highlightCloseness), scalar("highlightImpact", \.highlightImpact),
        scalar("highlightAuthorH", \.highlightAuthorH), scalar("profileFilled", \.profileFilled),
        scalar("dwellSeconds", \.dwellSeconds), scalar("useZotero", \.useZotero), scalar("useLibraryFile", \.useLibraryFile), scalar("zoteroRecent", \.zoteroRecent),
        scalar("hideMemory", \.hideMemory), scalar("hideHalfLifeMonths", \.hideHalfLifeMonths),
        scalar("likeMemory", \.likeMemory), scalar("likeHalfLifeMonths", \.likeHalfLifeMonths),
        scalar("hideStrength", \.hideStrength), scalar("likeStrength", \.likeStrength),
    ]

    /// Every decision a settings value holds, by key. An empty string is an item with no payload.
    static func items(of s: FeedSettings) -> [String: String] {
        var out: [String: String] = [:]
        for list in entityLists { for e in s[keyPath: list.path] { out["e/\(list.name)/\(e.id)"] = json(e) } }
        for k in s.followedKeywords { out["kw/\(k.id)"] = json(k) }
        for p in s.profileOrcids { out["po/\(p.orcid)"] = json(p) }
        for w in s.mutedKeywords { out["mw/\(w)"] = "" }
        for p in s.feedback.saved { out["sv/\(p.id)"] = json(p) }
        for p in s.feedback.liked { out["lk/\(p.id)"] = json(p) }
        for h in s.feedback.hidden { out["hd/\(h)"] = "" }
        for p in s.feedback.hiddenPapers { out["hp/\(p.id)"] = json(p) }
        for sc in scalars { out["v/\(sc.name)"] = sc.read(s) }
        return out
    }

    /// `existing` keeps its order, what is new follows in the order it was decided,
    /// and what was removed is gone. Where the item's value changed, the new one is used.
    private static func ordered<T: Decodable>(_ existing: [T], key: (T) -> String, prefix: String,
                                              entries: [String: SyncEntry]) -> [T] {
        var wanted: [String: (at: Date, item: T)] = [:]
        for (k, e) in entries where k.hasPrefix(prefix) && e.present {
            if let text = e.value, let item: T = value(text) { wanted[String(k.dropFirst(prefix.count))] = (e.at, item) }
        }
        var out: [T] = []
        var used: Set<String> = []
        for old in existing {
            let id = key(old)
            if let w = wanted[id] { out.append(w.item); used.insert(id) }
        }
        let fresh = wanted.filter { !used.contains($0.key) }.sorted { ($0.value.at, $0.key) < ($1.value.at, $1.key) }
        return out + fresh.map(\.value.item)
    }

    private static func orderedNames(_ existing: [String], prefix: String, entries: [String: SyncEntry]) -> [String] {
        var wanted: [String: Date] = [:]
        for (k, e) in entries where k.hasPrefix(prefix) && e.present { wanted[String(k.dropFirst(prefix.count))] = e.at }
        let kept = existing.filter { wanted[$0] != nil }
        let fresh = wanted.filter { !kept.contains($0.key) }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        return kept + fresh.map(\.key)
    }

    static func apply(_ entries: [String: SyncEntry], to settings: FeedSettings) -> FeedSettings {
        var s = settings
        for list in entityLists {
            s[keyPath: list.path] = ordered(s[keyPath: list.path], key: { $0.id }, prefix: "e/\(list.name)/", entries: entries)
        }
        s.followedKeywords = ordered(s.followedKeywords, key: { $0.id }, prefix: "kw/", entries: entries)
        s.profileOrcids = Array(ordered(s.profileOrcids, key: { $0.orcid }, prefix: "po/", entries: entries).prefix(3))
        s.mutedKeywords = orderedNames(s.mutedKeywords, prefix: "mw/", entries: entries)
        s.feedback.saved = ordered(s.feedback.saved, key: { $0.id }, prefix: "sv/", entries: entries)
        s.feedback.liked = ordered(s.feedback.liked, key: { $0.id }, prefix: "lk/", entries: entries)
        s.feedback.hidden = orderedNames(s.feedback.hidden, prefix: "hd/", entries: entries)
        s.feedback.hiddenPapers = ordered(s.feedback.hiddenPapers, key: { $0.id }, prefix: "hp/", entries: entries)
        for sc in scalars {
            if let e = entries["v/\(sc.name)"], e.present, let text = e.value { sc.write(&s, text) }
        }
        return s
    }
}

extension SyncDocument {
    /// Bring the record in line with the settings: whatever differs was changed
    /// here, just now (or at `now`, which a first run sets to when the settings
    /// file was last written, so that defaults never outrank another device's edit).
    mutating func reconcile(_ settings: FeedSettings, at now: Date) {
        let current = SyncProjection.items(of: settings)
        for (key, text) in current {
            let stored = text.isEmpty ? nil : text
            if let e = entries[key], e.present, e.value == stored { continue }
            entries[key] = SyncEntry(at: now, present: true, value: stored)
        }
        for (key, e) in entries where e.present && current[key] == nil {
            entries[key] = SyncEntry(at: now, present: false, value: nil)
        }
    }

    func apply(to settings: FeedSettings) -> FeedSettings {
        SyncProjection.apply(entries, to: settings)
    }
}
