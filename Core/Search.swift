import Foundation

// Searching the sources for a phrase, and what has been searched lately. A search ranks what it finds by the
// phrase, the levels the user set and what they have kept, and a recent search then counts as an interest of its
// own: it joins what stands for the user's work, and fades over about two weeks. Searches are kept on the
// device only, because what someone searches for says what they are working on. Pure and tested; the call
// to the sources is in Engine.swift.

struct Search: Codable, Equatable {
    var text: String
    /// Seconds since 1970.
    var at: Double
}

enum SearchLog {
    static let limit = 30
    /// A search counts half as much for every two weeks that pass.
    static let halfLifeDays = 14.0
    /// Below this share of its first weight a search counts for nothing.
    static let faded = 0.05

    /// The searches with this one added: newest first, a repeat moved to the top (not kept twice), no more than `limit`.
    static func adding(_ text: String, to log: [Search], at now: Date) -> [Search] {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count >= 2 else { return log }
        let others = log.filter { $0.text.lowercased() != clean.lowercased() }
        return Array(([Search(text: clean, at: now.timeIntervalSince1970)] + others).prefix(limit))
    }

    /// How much a search counts now.
    static func weight(_ search: Search, now: Date) -> Double {
        pow(0.5, max(now.timeIntervalSince1970 - search.at, 0) / (halfLifeDays * 86_400))
    }

    /// What recent searches add to what stands for the user's work: each phrase, with how much it still counts.
    static func entries(_ log: [Search], now: Date) -> [ProfileEntry] {
        log.compactMap { s in
            let w = weight(s, now: now)
            return w < faded ? nil : ProfileEntry(text: s.text, weight: w, title: s.text)
        }
    }
}

enum SearchRanking {
    /// How much the phrase itself counts beside what the user has kept: a search is for that phrase first.
    static let phraseWeight = 3.0

    /// The papers a search found, ranked: by the phrase, by what stands for the user's work (`profile`: what they
    /// kept, their projects and library, and recent searches) and by the levels they set, as the feed ranks.
    /// Nothing the user hid or muted is shown, as in the feed.
    static func rank(_ papers: [Paper], query: String, settings: FeedSettings, profile: [ProfileEntry],
                     embedder: TextEmbedder? = nil, today: Date, limit: Int = 100) -> [RankedPaper] {
        let kept = FeedBuilder.keep(papers, settings: settings)
        let entries = profile + [ProfileEntry(text: query, weight: phraseWeight, title: query)]
        return Array(Ranker.rank(kept, profile: entries, embedder: embedder, settings: settings, today: today).prefix(limit))
    }
}
