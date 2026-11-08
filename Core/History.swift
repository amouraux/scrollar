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
    /// Seconds the post was on screen (at least half of it, with the app in front), added up over
    /// every visit. nil for a state written before this was measured, or made by `markSeen`, which
    /// stands for "it was looked at" as it always did.
    var dwell: Double? = nil
}

/// How long a post was looked at, in the three levels the feed acts on.
enum Attention: Equatable {
    /// Under `Dwell.glance`: flicked past, still new.
    case passed
    /// Looked at: it sinks below what is new.
    case glanced
    /// Looked at for the user's own number of seconds, or marked "for me": it sinks further and expires sooner.
    case studied
}

enum Dwell {
    /// Below this a post was passing through the screen, not looked at.
    static let glance = 1.5
    /// A studied post expires after this many days at most, whatever the seen-expiry setting says: the user
    /// has looked at it properly, so it need not wait a week to leave the top.
    static let studiedExpiryDays = 2
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
        if s.opened != nil { return .read }
        // Measured: under the glance threshold it is still new. Not measured (an older record): seen.
        if let d = s.dwell { return d >= Dwell.glance ? .seen : .new }
        return .seen
    }

    /// How closely the post was looked at, for one that has been seen. `studiedAfter` is the user's setting.
    func attention(of key: String, studiedAfter: Double) -> Attention {
        guard let d = states[key]?.dwell else { return states[key] == nil ? .passed : .glanced }
        return d >= studiedAfter ? .studied : d >= Dwell.glance ? .glanced : .passed
    }

    /// Add the seconds a post was on screen. The first sighting is the first time it was on screen at all,
    /// so a flick is remembered even though it does not make the post seen.
    mutating func addDwell(_ key: String, seconds: Double, at now: Date) {
        guard seconds > 0 else { return }
        var s = states[key] ?? PaperState(firstSeen: now, lastSeen: now, seenCount: 0)
        s.lastSeen = now
        s.dwell = (s.dwell ?? (s.seenCount > 0 ? Dwell.glance : 0)) + seconds
        if s.dwell! >= Dwell.glance { s.seenCount = max(s.seenCount, 1) }
        states[key] = s
    }

    /// "This is for me" counts as having studied it: it was recognised as worth the user's attention.
    mutating func markStudied(_ key: String, studiedAfter: Double, at now: Date) {
        var s = states[key] ?? PaperState(firstSeen: now, lastSeen: now, seenCount: 1)
        s.lastSeen = now
        s.seenCount = max(s.seenCount, 1)
        s.dwell = max(s.dwell ?? 0, studiedAfter)
        states[key] = s
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
    /// "From what you follow": every paper that something the user follows found, newest
    /// first, taken out of the ranked list so a card is never shown twice. The ranking
    /// decides what is worth reading among the rest; for what they follow they asked to
    /// see everything, so nothing about similarity or a cut-off applies to it.
    static func split(_ ranked: [RankedPaper], followSection: Bool, keywords: [KeywordRule] = []) -> (followed: [RankedPaper], rest: [RankedPaper]) {
        guard followSection else { return ([], ranked) }
        var followed: [RankedPaper] = []
        var rest: [RankedPaper] = []
        for r in ranked { if r.paper.isPinned { followed.append(r) } else { rest.append(r) } }
        // High keywords first, then the rest; newest first within each. A paper something other
        // than a keyword also found is at least Normal, whatever its keywords say.
        var settings = FeedSettings()
        settings.followedKeywords = keywords
        func tier(_ p: Paper) -> Int {
            let byKeyword = settings.keywordImportance(of: p)
            let byOther = p.reasons.contains { !$0.hasPrefix("Keyword: ") && !Paper.broadReasonPrefixes.contains(where: $0.hasPrefix) }
            if let k = byKeyword { return byOther ? max(k.tier, Importance.normal.tier) : k.tier }
            return Importance.normal.tier
        }
        followed.sort {
            if tier($0.paper) != tier($1.paper) { return tier($0.paper) > tier($1.paper) }
            if $0.paper.date != $1.paper.date { return $0.paper.date > $1.paper.date }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.paper.dedupeKey < $1.paper.dedupeKey
        }
        return (followed, rest)
    }

    /// Sort a ranked list into new, earlier and read. This is computed when the
    /// feed is loaded or refreshed, not as the user scrolls: a card that moved
    /// the moment it was seen would jump away under their finger.
    static func arrange(_ ranked: [RankedPaper], history: History, settings: FeedSettings, now: Date) -> Arranged {
        var out = Arranged()
        // Papers the user looked at properly go below those they only glanced at.
        var studied: [RankedPaper] = []
        for r in ranked {
            let key = r.paper.dedupeKey
            switch history.status(of: key) {
            case .new:
                out.fresh.append(r)
            case .seen:
                // Measured from the first sighting: scrolling back to an old card
                // must not keep it alive for ever.
                let age = history.states[key].map { now.timeIntervalSince($0.firstSeen) / 86_400 } ?? 0
                if history.attention(of: key, studiedAfter: settings.dwellSeconds) == .studied {
                    if age <= Double(min(settings.seenExpiryDays, Dwell.studiedExpiryDays)) { studied.append(r) }
                } else if age <= Double(settings.seenExpiryDays) {
                    out.earlier.append(r)
                }
            case .read:
                out.read.append(r)
            }
        }
        out.earlier += studied
        return out
    }
}
