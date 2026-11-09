import Foundation

/// Sorting and filtering a list of kept papers (Saved, For me, Read) by how each one is classified
/// for the user: the reasons it reached the feed. Pure, so it is tested without a window.
struct SavedFilter: Equatable {
    enum Sort: String, CaseIterable {
        /// The list's own order: the latest kept first.
        case kept = "Latest kept"
        case published = "Publication date"
        /// The most specific reason first (cites your work, an author you follow, … a topic), then
        /// the papers with more reasons.
        case relevance = "Relevance to me"
    }

    var kind: Why.Kind? = nil
    /// With `kind`: one name within it (an author, a topic). Nil is every paper of that kind.
    var detail: String? = nil
    var query = ""
    var sort = Sort.kept

    var isActive: Bool { kind != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Entries kept before reasons were stored get them from the feed, where it still holds the paper.
    /// What the feed does not know stays unclassified rather than guessed.
    static func enriched(_ items: [SavedPaper], from feed: [Paper]) -> [SavedPaper] {
        guard items.contains(where: { $0.reasons == nil }) else { return items }
        var byKey: [String: Paper] = [:]
        for p in feed where !p.reasons.isEmpty { byKey[p.dedupeKey] = p }
        return items.map { item in
            guard item.reasons == nil, let p = byKey[item.id] else { return item }
            var copy = item
            copy.reasons = p.reasons
            copy.followed = p.followed
            return copy
        }
    }

    static func tags(of item: SavedPaper) -> [Why.Tag] {
        Why.tags(reasons: item.reasons ?? [], followed: item.followed ?? false)
    }

    /// One row of the panel: a kind, or a name within a kind, and how many papers carry it.
    struct Facet: Hashable {
        var kind: Why.Kind
        /// Nil for the kind as a whole.
        var detail: String?
        var count: Int
    }

    /// Every kind present, each followed by its names, most specific kind first and the commonest
    /// name first. A paper counts once per facet however many of its reasons match, and papers
    /// with no stored reason are counted under `.other`.
    static func facets(_ items: [SavedPaper]) -> [Facet] {
        var kinds: [Why.Kind: Int] = [:]
        var details: [Why.Kind: [String: Int]] = [:]
        for item in items {
            let tags = tags(of: item)
            for kind in Set(tags.map(\.kind)) { kinds[kind, default: 0] += 1 }
            for tag in Set(tags) where !tag.detail.isEmpty { details[tag.kind, default: [:]][tag.detail, default: 0] += 1 }
            if tags.isEmpty { kinds[.other, default: 0] += 1 }
        }
        var out: [Facet] = []
        for kind in Why.Kind.allCases {
            guard let n = kinds[kind] else { continue }
            out.append(Facet(kind: kind, detail: nil, count: n))
            let names = (details[kind] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            // A single name for a whole kind says the same thing twice.
            if names.count > 1 || (names.count == 1 && names[0].value < n) {
                out += names.map { Facet(kind: kind, detail: $0.key, count: $0.value) }
            }
        }
        return out
    }

    func apply(_ items: [SavedPaper]) -> [SavedPaper] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let kept = items.filter { item in
            if let kind {
                let tags = Self.tags(of: item)
                if tags.isEmpty { guard kind == .other, detail == nil else { return false } }
                else if let detail { guard tags.contains(Why.Tag(kind: kind, detail: detail)) else { return false } }
                else { guard tags.contains(where: { $0.kind == kind }) else { return false } }
            }
            if words.isEmpty { return true }
            let hay = ([item.title, item.journal ?? ""] + (item.authors ?? [])).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        switch sort {
        case .kept:
            return kept
        case .published:
            // Dates are ISO, so text order is date order. Stable: ties keep the list's order.
            return kept.enumerated().sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }.map(\.element)
        case .relevance:
            func score(_ i: SavedPaper) -> (Int, Int) {
                let t = Self.tags(of: i)
                return (t.first?.kind.rawValue ?? Why.Kind.other.rawValue + 1, -t.count)
            }
            return kept.enumerated().sorted {
                let a = score($0.element), b = score($1.element)
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        }
    }
}
