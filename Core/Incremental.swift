import Foundation

// Asking for only what is new since the last refresh, and keeping the rest.
//
// OpenAlex's "added since" filters (from_created_date, from_updated_date) belong
// to its paid plans, and the creation dates it returns are not trustworthy
// anyway (a paper published on 6 November reported March). So "new" can only mean
// "published recently", and a paper OpenAlex indexes weeks after its publication
// date slips past an incremental fetch. That is why a full rebuild still happens
// every few days, whenever the settings change, and after a long absence.

struct PreviousFeed {
    /// Every paper of the last feed, before the user's feedback was applied again.
    var papers: [Paper]
    /// The last fetch that every seed answered covered papers up to here.
    var fetchedThrough: Date
    /// When the whole look-back window was last fetched from scratch.
    var fullBuildAt: Date
    /// The settings (without feedback) the papers were fetched for: their
    /// reasons and flags are only valid for those.
    var builtWith: FeedSettings
    /// Days held beyond the look-back, fetched when the reader scrolled to the end.
    var extraDays = 0
}

enum Incremental {
    /// Papers published up to this many days before the last fetch are asked for
    /// again, because a record often appears in OpenAlex a day or two late.
    static let overlapDays = 3
    static let fullRebuildDays = 3.0

    /// Scrolling to the end asks for the days before the ones held, this many at a time, up
    /// to a year in all. A full rebuild forgets them: it fetches the look-back only, and
    /// scrolling to the end fetches them again.
    static let olderStep = 30
    static let furthestDays = 365

    /// The days to ask for next, as yyyy-MM-dd bounds, and how many extra days are then held;
    /// nil once a year is held.
    static func olderRange(now: Date, daysBack: Int, extraDays: Int) -> (since: String, until: String, extraDays: Int)? {
        let held = daysBack + extraDays
        guard held < furthestDays else { return nil }
        let step = min(olderStep, furthestDays - held)
        func day(_ n: Int) -> String { Ranker.dayString(now.addingTimeInterval(-Double(n) * 86_400)) }
        return (day(held + step), day(held), extraDays + step)
    }

    enum Mode: Equatable {
        case full(reason: String)
        /// Ask only for papers published on or after this day (yyyy-MM-dd).
        case incremental(since: String)
        /// The days before the ones held, between these two (yyyy-MM-dd, both included).
        case older(since: String, until: String)

        var isIncremental: Bool {
            if case .incremental = self { return true }
            return false
        }
    }

    static func mode(previous: PreviousFeed?, settings: FeedSettings, now: Date) -> Mode {
        guard let p = previous else { return .full(reason: "first build") }
        // Different follows or mutes make the kept papers' reasons wrong. Feedback
        // and the ranking sliders are excluded: they reorder the kept set, they do
        // not change what must be fetched.
        if p.builtWith.forFetching != settings.forFetching { return .full(reason: "settings changed") }
        // Kept papers from before authors' institutions were recorded would show
        // no affiliation until the next scheduled rebuild.
        if !p.papers.isEmpty, p.papers.allSatisfy({ $0.firstInstitution == nil && $0.lastInstitution == nil }) {
            return .full(reason: "adding authors' institutions to the cached papers")
        }
        if now.timeIntervalSince(p.fullBuildAt) / 86_400 > fullRebuildDays {
            return .full(reason: "rebuilding everything, as every \(Int(fullRebuildDays)) days")
        }
        if now.timeIntervalSince(p.fetchedThrough) / 86_400 >= Double(settings.daysBack) {
            return .full(reason: "away for longer than the look-back")
        }
        let overlapStart = Ranker.dayString(p.fetchedThrough.addingTimeInterval(-Double(overlapDays) * 86_400))
        let windowStart = Ranker.dayString(now.addingTimeInterval(-Double(settings.daysBack) * 86_400))
        // yyyy-MM-dd compares correctly as text. Never reach back past the window.
        return .incremental(since: max(overlapStart, windowStart))
    }

    /// A freshly fetched copy of a paper has none of what PubMed added last time
    /// (an abstract OpenAlex lacked, the publication types, a PMID found by DOI),
    /// and fetching it again costs a request per hundred papers. PubMed's answer
    /// does not depend on the user's settings, so it is carried over in every mode.
    static func carryOver(from previous: [Paper], into fresh: [Paper]) -> [Paper] {
        var known: [String: Paper] = [:]
        for p in previous where !p.pubmedTypes.isEmpty || p.abstractFromPubMed || p.pmid != nil || p.notInPubMed == true {
            known[p.dedupeKey] = p
        }
        return fresh.map { paper in
            guard let old = known[paper.dedupeKey] else { return paper }
            var p = paper
            if p.pmid == nil { p.pmid = old.pmid }
            if p.notInPubMed == nil { p.notInPubMed = old.notInPubMed }
            if p.pubmedTypes.isEmpty { p.pubmedTypes = old.pubmedTypes }
            if p.abstract == nil, let a = old.abstract {
                p.abstract = a
                p.abstractFromPubMed = old.abstractFromPubMed
            }
            return p
        }
    }

    /// Papers still inside the look-back, plus what was just fetched. A fresh
    /// copy comes first, so where both have a field the newer one is kept.
    static func merge(previous: [Paper], fresh: [Paper], windowStart: String) -> [Paper] {
        Merge.combine(fresh + previous.filter { $0.date >= windowStart })
    }
}
