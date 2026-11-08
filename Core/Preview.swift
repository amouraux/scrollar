import Foundation

/// What following something would put in the feed, shown before (or while) the user decides:
/// the newest papers it finds in the look-back, with the same words, mutes and filters the
/// feed applies. A keyword as broad as "pain" is a different thing once the user sees it.
struct SeedPreview: Equatable {
    /// Newest first, at most `Previews.shown`.
    var papers: [Paper]
    /// How many papers the follow would put in the feed, of those fetched.
    var matched: Int
    /// Fetched, then dropped by the keyword's own words, a mute or a filter.
    var removed: Int
    /// A source returned a full page, so there are more than were fetched.
    var mayHaveMore: Bool
}

enum Previews {
    static let shown = 30
    /// What a source returns in one request, which is all a preview asks for.
    static let pageSize = 100

    /// `fetched` is what the sources returned for `seed`. `rule` carries a keyword's own
    /// conditions when it has any; they apply here exactly as `FeedBuilder.keep` applies them.
    static func make(_ fetched: [Paper], seed: Seed, rule: KeywordRule? = nil, settings: FeedSettings, fullPage: Bool) -> SeedPreview {
        var merged = Merge.combine(fetched)
        for i in merged.indices { merged[i].reasons = [seed.reason] }
        let candidates = merged.filter { p in
            rule?.accepts((p.title + " " + (p.abstract ?? "")).lowercased()) ?? true
        }
        let kept = FeedBuilder.keep(candidates, settings: settings)
        let newest = kept.sorted { $0.date != $1.date ? $0.date > $1.date : $0.title < $1.title }
        return SeedPreview(papers: Array(newest.prefix(shown)), matched: kept.count,
                           removed: merged.count - kept.count, mayHaveMore: fullPage)
    }
}

extension Seed {
    /// The search a followed topic stands for: its OpenAlex id, or, for a topic taken from a
    /// paper's MeSH headings, the heading in Europe PMC. nil for a heading too general to follow.
    /// One place, so the feed and the preview ask for the same thing.
    static func forTopic(_ e: Entity) -> Seed? {
        if e.id.hasPrefix("mesh:") { return MeSH.isGeneric(e.name) ? nil : .mesh(e.name) }
        return .topic(id: e.id, name: e.name)
    }
}
