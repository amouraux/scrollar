import Foundation

// What is on screen, worked out from a ranked feed. Pure, so the order a reader sees can be tested.

/// A paper that fits particularly well, and why, in words.
struct Highlight {
    var ranked: RankedPaper
    var reason: String
}

enum Highlights {
    /// The few fresh papers that are both very close to the user's own work and have something
    /// more going for them, best first. Closeness alone is not enough: the second thing is what
    /// makes it worth interrupting the feed for, and every part of the rule is a setting.
    static func select(_ fresh: [RankedPaper], settings s: FeedSettings) -> [Highlight] {
        guard s.highlightCount > 0 else { return [] }
        return fresh
            .filter { $0.similarity >= s.highlightCloseness }
            .compactMap { r -> Highlight? in
                let signals = Highlights.signals(for: r.paper, settings: s)
                guard !signals.isEmpty else { return nil }
                return Highlight(ranked: r, reason: (["very close to your work"] + signals).joined(separator: " · "))
            }
            .sorted { $0.ranked.score != $1.ranked.score ? $0.ranked.score > $1.ranked.score : $0.ranked.paper.dedupeKey < $1.ranked.paper.dedupeKey }
            .prefix(s.highlightCount)
            .map { $0 }
    }

    /// What, besides being close, makes a paper stand out.
    static func signals(for p: Paper, settings s: FeedSettings) -> [String] {
        var out: [String] = []
        if s.highlightImpact > 0, let impact = p.journalImpact, impact >= s.highlightImpact {
            out.append("journal impact " + String(format: "%.1f", impact))
        }
        if s.highlightAuthorH > 0, let h = Ranker.chosenH(p, focus: s.byline), h >= s.highlightAuthorH {
            let who = s.byline == .last ? "senior author " : s.byline == .first ? "first author " : "author "
            out.append(who + "h-index \(h)")
        }
        if p.citesYou { out.append("cites your work") }
        if p.isPinned { out.append("from something you follow") }
        return out
    }
}

extension Arranger {
    /// A ranked list cut to its best `cap`, except that nothing a journal, researcher or keyword the
    /// user follows found is ever cut: following something is a request to see it, so a low score
    /// only decides where it sits. The order is kept.
    static func blend(_ ranked: [RankedPaper], cap: Int) -> [RankedPaper] {
        var others = 0
        return ranked.filter { r in
            if r.paper.isPinned { return true }
            others += 1
            return others <= cap
        }
    }
}

struct FeedLayout {
    static let freshCap = 150
    static let earlierCap = 60
    static let readCap = 60

    var highlights: [Highlight] = []
    /// New papers older than the look-back, best first: what scrolling to the end fetched.
    /// They go after everything else new so the list only ever grows downwards.
    var older: [RankedPaper] = []
    /// Everything else, ranked.
    var feed = Arranged()

    var isEmpty: Bool { highlights.isEmpty && older.isEmpty && feed.isEmpty }

    /// Every paper still on screen, as a place to look for one.
    var all: [RankedPaper] {
        highlights.map(\.ranked) + older + feed.fresh + feed.earlier + feed.read
    }

    static func make(citedYou: [RankedPaper], forYou: [RankedPaper], history: History,
                     settings: FeedSettings, now: Date) -> FeedLayout {
        var layout = FeedLayout()
        func byScore(_ a: RankedPaper, _ b: RankedPaper) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.paper.date != b.paper.date { return a.paper.date > b.paper.date }
            return a.paper.dedupeKey < b.paper.dedupeKey
        }
        func removing(_ keys: Set<String>, from a: Arranged) -> Arranged {
            var out = a
            out.fresh.removeAll { keys.contains($0.paper.dedupeKey) }
            return out
        }

        // Papers older than the look-back are shown last, whatever they score: a stronger one
        // fetched later must not appear above what the reader has already scrolled past.
        let windowStart = Ranker.dayString(now.addingTimeInterval(-Double(settings.daysBack) * 86_400))
        func isOlder(_ r: RankedPaper) -> Bool { r.paper.date < windowStart }
        // Further back is fetched 30 days at a time. Ordering by that step first, and by score
        // inside it, means a step fetched later always lands below the ones the reader has
        // scrolled through, however well its papers score.
        let boundaries = (1...12).map { Ranker.dayString(now.addingTimeInterval(-Double(settings.daysBack + Incremental.olderStep * $0) * 86_400)) }
        func step(_ r: RankedPaper) -> Int { boundaries.filter { r.paper.date < $0 }.count }
        func furtherBack(_ list: [RankedPaper]) -> [RankedPaper] {
            list.filter(isOlder).sorted { step($0) != step($1) ? step($0) < step($1) : byScore($0, $1) }
        }
        func withoutOlder(_ a: Arranged) -> Arranged {
            var out = a
            out.fresh.removeAll(where: isOlder)
            return out
        }

        let everything = (citedYou + forYou).sorted(by: byScore)
        var arranged = Arranger.arrange(everything, history: history, settings: settings, now: now)
        layout.older = furtherBack(arranged.fresh)
        arranged = withoutOlder(arranged)
        layout.highlights = Highlights.select(arranged.fresh, settings: settings)
        arranged = removing(Set(layout.highlights.map { $0.ranked.paper.dedupeKey }), from: arranged)
        // No cut-off: the list goes as far as what is held, and then further back.
        arranged.earlier = Arranger.blend(arranged.earlier, cap: earlierCap)
        arranged.read = Array(arranged.read.prefix(readCap))
        layout.feed = arranged
        return layout
    }
}
