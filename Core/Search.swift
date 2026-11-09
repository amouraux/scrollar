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

enum SearchTerms {
    /// Little words that would only narrow a search to titles that happen to contain them.
    static let little: Set<String> = ["a", "an", "and", "at", "by", "for", "in", "of", "on", "or", "the", "to", "with"]

    /// The terms of a search: each word on its own, so a paper needs every word but not in that order, and a
    /// phrase in quotes kept whole. Little words are dropped unless they are all there is.
    static func terms(_ query: String) -> [String] {
        var out: [String] = []
        var current = "", quoted = false
        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        for ch in query {
            if ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" { flush(); quoted.toggle() }
            else if ch.isWhitespace && !quoted { flush() }
            else { current.append(ch) }
        }
        flush()
        let kept = out.filter { !little.contains($0.lowercased()) }
        return kept.isEmpty ? out : kept
    }

    /// What the sources are asked for: the first term, and the others as conditions beside it, which every source
    /// reads as "this AND that" (an unadorned phrase is read by Europe PMC and arXiv as an exact string).
    static func seed(_ query: String) -> Seed {
        let t = terms(query)
        guard let first = t.first else { return .keyword(query) }
        return .keyword(first, also: Array(t.dropFirst()))
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
