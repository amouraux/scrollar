import Foundation

// Catching up on one topic: the feed narrowed to the papers that are there for a given reason (an author, a
// keyword, a journal, a topic the user follows). The reasons are the ones each post already names. Pure,
// so it is tested without a window.

struct FeedFilter: Equatable {
    var kind: Why.Kind?
    /// With `kind`: one name within it (an author, a topic). Nil is every paper of that kind.
    var detail: String?

    var isActive: Bool { kind != nil }

    /// A kind as the panel heads its group: short, in the plural, since the panel is already about why a paper is there.
    static func heading(_ kind: Why.Kind) -> String {
        switch kind {
        case .citesYou: return "Cites your work"
        case .citesTracked: return "Cites a paper you track"
        case .author: return "Authors"
        case .keyword: return "Keywords"
        case .journal: return "Journals"
        case .institution: return "Institutions"
        case .funder: return "Funders"
        case .followedTopic: return "Topics you follow"
        case .ownTopic: return "Topics from your papers"
        case .other: return "Other"
        }
    }

    /// What a paper counts under: each of its reasons, and `.other` when it has none.
    static func tags(of paper: Paper) -> [Why.Tag] {
        Why.tags(reasons: paper.reasons, followed: paper.followed)
    }

    func matches(_ paper: Paper) -> Bool {
        guard let kind else { return true }
        let tags = Self.tags(of: paper)
        if tags.isEmpty { return kind == .other && detail == nil }
        return tags.contains { $0.kind == kind && (detail == nil || $0.detail == detail) }
    }

    /// One row of the panel: a kind, or a name within a kind, how many papers carry it, and how many of
    /// those have not been looked at.
    struct Facet: Hashable {
        var kind: Why.Kind
        /// Nil for the kind as a whole.
        var detail: String?
        var count: Int
        var new: Int
    }

    /// The order the panel lists the kinds in: what a person catches up on first (the subjects), then who and where,
    /// then the rest. Kept apart from `Why.Kind`'s own order, which the posts and the reasons use.
    static let panelOrder: [Why.Kind] = [
        .followedTopic, .ownTopic, .keyword, .author, .journal, .citesYou, .citesTracked, .institution, .funder, .other,
    ]

    /// Every kind present, each followed by its names (the commonest first), in `panelOrder`. A
    /// paper counts once per facet however many of its reasons match. Read papers count only if they are shown.
    static func facets(_ layout: FeedLayout, includeRead: Bool) -> [Facet] {
        var kinds: [Why.Kind: (count: Int, new: Int)] = [:]
        var details: [Why.Kind: [String: (count: Int, new: Int)]] = [:]
        for (ranked, isNew) in layout.entries(includeRead: includeRead) {
            let tags = tags(of: ranked.paper)
            for kind in Set(tags.isEmpty ? [.other] : tags.map(\.kind)) {
                let old = kinds[kind] ?? (0, 0)
                kinds[kind] = (old.count + 1, old.new + (isNew ? 1 : 0))
            }
            for tag in Set(tags) where !tag.detail.isEmpty {
                let old = details[tag.kind]?[tag.detail] ?? (0, 0)
                details[tag.kind, default: [:]][tag.detail] = (old.count + 1, old.new + (isNew ? 1 : 0))
            }
        }
        var out: [Facet] = []
        for kind in panelOrder {
            guard let total = kinds[kind] else { continue }
            out.append(Facet(kind: kind, detail: nil, count: total.count, new: total.new))
            let names = (details[kind] ?? [:]).sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            // A single name for a whole kind says the same thing twice.
            if names.count > 1 || (names.count == 1 && names[0].value.count < total.count) {
                out += names.map { Facet(kind: kind, detail: $0.key, count: $0.value.count, new: $0.value.new) }
            }
        }
        return out
    }
}

extension FeedLayout {
    /// Every paper on the layout, with whether it has not been looked at yet.
    func entries(includeRead: Bool) -> [(RankedPaper, Bool)] {
        var out: [(RankedPaper, Bool)] = highlights.map { ($0.ranked, true) } + older.map { ($0, true) }
        out += feed.fresh.map { ($0, true) } + feed.earlier.map { ($0, false) }
        if includeRead { out += feed.read.map { ($0, false) } }
        return out
    }

    /// Only the papers that are there for the reason chosen.
    func filtered(by filter: FeedFilter) -> FeedLayout {
        guard filter.isActive else { return self }
        func keep(_ list: [RankedPaper]) -> [RankedPaper] { list.filter { filter.matches($0.paper) } }
        func keep(_ a: Arranged) -> Arranged { Arranged(fresh: keep(a.fresh), earlier: keep(a.earlier), read: keep(a.read)) }
        var out = self
        out.highlights = highlights.filter { filter.matches($0.ranked.paper) }
        out.older = keep(older)
        out.feed = keep(feed)
        return out
    }
}
