import Foundation

// How long and how hard the user's thumbs count. A paper put on the reading list or marked For me
// pulls the feed toward what is like it; a paper hidden pushes the feed away from what is like it.
// Interests move, so neither lasts for ever: only the newest few count, the oldest of those a quarter
// as much as the newest, and an age limit can drop the rest. Pure and tested; the ranking that uses
// these is in Ranking.swift.

/// One text that stands for something the user likes (a profile) or avoids, with how much it counts.
struct ProfileEntry: Equatable {
    var text: String
    /// 0 to 1; 1 for everything that is not a thumb (the user's own papers, the library, the project).
    var weight: Double = 1
    /// The paper's title, for a paper the user kept or hid, so the screen that explains the ranking can
    /// name it. nil for everything else.
    var title: String? = nil
}

enum FeedbackMemory {
    /// What the oldest paper inside the window counts for, against 1 for the newest.
    static let floor = 0.25

    /// Below this share of its first weight a paper counts for nothing, and takes no place in the window.
    static let faded = 0.05

    /// How much each paper counts, from a list kept oldest first. Two things lower it. Its place in the
    /// window: only the newest `memory` count, the newest in full and the oldest of them `floor` as much.
    /// And its age: it halves every `halfLifeMonths` (0 for no fade). A paper the user said to ignore,
    /// one beyond the window and one faded to almost nothing count for nothing and take no place in the
    /// window. A paper with no date does not fade: only the order says how recent it is.
    static func weights(_ items: [SavedPaper], memory: Int, halfLifeMonths: Int, now: Date) -> [Double] {
        var out = [Double](repeating: 0, count: items.count)
        guard memory > 0 else { return out }
        let halfLife: Double? = halfLifeMonths > 0 ? Double(halfLifeMonths) * 30.4375 * 86_400 : nil
        var rank = 0
        for i in items.indices.reversed() {
            let item = items[i]
            if item.ignored == true { continue }
            var age = 1.0
            if let halfLife, let kept = item.keptAt {
                age = pow(0.5, max(now.timeIntervalSince1970 - kept, 0) / halfLife)
                if age < faded { continue }
            }
            if rank >= memory { break }
            out[i] = (floor + (1 - floor) * (1 - Double(rank) / Double(memory))) * age
            rank += 1
        }
        return out
    }

    /// How a paper stands, in words, for the screen that lists them.
    static func standing(weight: Double, ignored: Bool) -> String {
        if ignored { return "Ignored" }
        if weight <= 0 { return "No longer counted" }
        if weight >= 0.8 { return "Counts fully" }
        if weight >= 0.4 { return "Counts partly" }
        return "Fading"
    }
}

extension FeedBuilder {
    /// Everything that stands for what the user is into, each with its weight: their own papers, what
    /// is on their reading list or marked For me (the newest of them, in the order kept, faded and cut
    /// as the settings say), their library and their project. What does not count at all is left out.
    static func profile(_ s: FeedSettings, own: [Paper], library: [String] = [], project: [String] = [],
                        searches: [ProfileEntry] = [], now: Date = Date()) -> [ProfileEntry] {
        func text(_ title: String, _ abstract: String?) -> String { title + ". " + (abstract ?? "") }
        var entries: [ProfileEntry] = s.useMyPublications ? own.map { ProfileEntry(text: text($0.title, $0.abstract)) } : []
        let pool = FeedbackMemory.likedPool(s)
        let weights = FeedbackMemory.weights(pool, memory: s.likeMemory, halfLifeMonths: s.likeHalfLifeMonths, now: now)
        if s.likeStrength > 0 {
            for (paper, w) in zip(pool, weights) where w > 0 {
                entries.append(ProfileEntry(text: text(paper.title, paper.abstract), weight: w * s.likeStrength, title: paper.title))
            }
        }
        if s.useZotero || s.useLibraryFile { entries += library.map { ProfileEntry(text: $0) } }
        entries += project.map { ProfileEntry(text: $0) }
        // What was searched for lately, each fading, when the user lets it count.
        if s.countsSearches { entries += searches }
        return entries
    }

    /// What the user hid and the feed should move away from, each with its weight. Empty when hides do
    /// not count (strength off) or none was kept with its text.
    static func avoid(_ s: FeedSettings, now: Date = Date()) -> [ProfileEntry] {
        guard s.hideStrength > 0 else { return [] }
        let weights = FeedbackMemory.weights(s.feedback.hiddenPapers, memory: s.hideMemory,
                                             halfLifeMonths: s.hideHalfLifeMonths, now: now)
        return zip(s.feedback.hiddenPapers, weights).filter { $0.1 > 0 }.map { paper, w in
            ProfileEntry(text: paper.title + ". " + (paper.abstract ?? ""), weight: w, title: paper.title)
        }
    }
}

extension FeedbackMemory {
    /// The reading list and For me are one pool: the newest across both, undated ones oldest.
    static func likedPool(_ s: FeedSettings) -> [SavedPaper] {
        (s.feedback.saved + s.feedback.liked).enumerated().sorted { a, b in
            let (x, y) = (a.element.keptAt ?? -.infinity, b.element.keptAt ?? -.infinity)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// How much each paper on the reading list or marked For me counts, by id (the higher where a
    /// paper is on both), before the strength setting.
    static func likeWeights(_ s: FeedSettings, now: Date = Date()) -> [String: Double] {
        let pool = FeedbackMemory.likedPool(s)
        let weights = Self.weights(pool, memory: s.likeMemory, halfLifeMonths: s.likeHalfLifeMonths, now: now)
        return Dictionary(zip(pool.map(\.id), weights), uniquingKeysWith: max)
    }

    /// How much each hidden paper counts, by id.
    static func hideWeights(_ s: FeedSettings, now: Date = Date()) -> [String: Double] {
        let weights = Self.weights(s.feedback.hiddenPapers, memory: s.hideMemory, halfLifeMonths: s.hideHalfLifeMonths, now: now)
        return Dictionary(zip(s.feedback.hiddenPapers.map(\.id), weights), uniquingKeysWith: max)
    }
}
