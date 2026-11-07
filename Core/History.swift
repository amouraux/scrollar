import Foundation

// What the user has seen and read. Kept apart from the settings on purpose:
// settings are things the user chose, this is a record of behaviour, and it can
// be lost without losing anything they entered. Foundation only, so it is tested.

struct PaperState: Codable, Equatable {
    var firstSeen: Date
    var lastSeen: Date
    var seenCount: Int
    /// Opened, expanded or otherwise read in depth.
    var opened: Date?
    /// Kept only for read papers, so a list of them can show titles without
    /// the paper still being in any feed.
    var snapshot: SavedPaper?
}

struct History: Codable, Equatable {
    /// Keyed by `Paper.dedupeKey`.
    var states: [String: PaperState] = [:]

    enum Status: Equatable {
        case new    // never shown
        case seen   // scrolled past
        case read   // opened in depth
    }

    func status(of key: String) -> Status {
        guard let s = states[key] else { return .new }
        return s.opened == nil ? .seen : .read
    }

    mutating func markSeen(_ key: String, at now: Date) {
        if var s = states[key] {
            s.lastSeen = now
            s.seenCount += 1
            states[key] = s
        } else {
            states[key] = PaperState(firstSeen: now, lastSeen: now, seenCount: 1)
        }
    }

    mutating func markOpened(_ paper: Paper, at now: Date) {
        let key = paper.dedupeKey
        var s = states[key] ?? PaperState(firstSeen: now, lastSeen: now, seenCount: 0)
        s.lastSeen = now
        if s.opened == nil {
            s.opened = now
            s.snapshot = SavedPaper(paper)
        }
        states[key] = s
    }

    /// Read papers, most recently read first.
    var read: [(paper: SavedPaper, date: Date)] {
        states.values
            .compactMap { s in s.opened.flatMap { d in s.snapshot.map { ($0, d) } } }
            .sorted { $0.date > $1.date }
    }

    /// A state must outlive the longest look-back a user can choose (365 days),
    /// or an old paper that is still in the window would turn "new" again.
    mutating func prune(now: Date, keepDays: Int = 400) {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        states = states.filter { $0.value.lastSeen >= cutoff }
    }
}

struct Arranged {
    /// Never shown. Ranked best first.
    var fresh: [RankedPaper] = []
    /// Seen but not read, and not yet expired. Ranked best first.
    var earlier: [RankedPaper] = []
    /// Read in depth. Not shown unless the user asks.
    var read: [RankedPaper] = []

    var isEmpty: Bool { fresh.isEmpty && earlier.isEmpty }
}

enum Arranger {
    /// Sort a ranked list into new, earlier and read. This is computed when the
    /// feed is loaded or refreshed, not as the user scrolls: a card that moved
    /// the moment it was seen would jump away under their finger.
    static func arrange(_ ranked: [RankedPaper], history: History, settings: FeedSettings, now: Date) -> Arranged {
        var out = Arranged()
        for r in ranked {
            let key = r.paper.dedupeKey
            switch history.status(of: key) {
            case .new:
                out.fresh.append(r)
            case .seen:
                // Measured from the first sighting: scrolling back to an old card
                // must not keep it alive for ever.
                let age = history.states[key].map { now.timeIntervalSince($0.firstSeen) / 86_400 } ?? 0
                if age <= Double(settings.seenExpiryDays) { out.earlier.append(r) }
            case .read:
                out.read.append(r)
            }
        }
        return out
    }
}
