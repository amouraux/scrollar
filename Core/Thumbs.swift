import Foundation

// What a thumb is about. A paper has many things that could be why it is liked or not: a keyword that found
// it, its journal, its authors, its topics. Asking which makes the effect of a thumb something the user chose
// and can see: the one thing picked, the best reason, moves one level (see Levels.swift), up for a thumb up and down for a thumb
// down. Pure and tested; the question is a sheet.

enum Keywords {
    /// A paper's keywords made fit to offer: trimmed, none empty or very long, none twice (in any case), at most
    /// `limit`. nil when none is left.
    static func clean(_ names: [String], limit: Int = 6) -> [String]? {
        var seen = Set<String>()
        let kept = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 60 && seen.insert($0.lowercased()).inserted }
        return kept.isEmpty ? nil : Array(kept.prefix(limit))
    }
}

enum ThumbBasis {
    struct Candidate: Hashable {
        var ref: FacetRef
        /// The level it has now.
        var level: Level
    }

    private static func list(_ kind: FacetKind, in s: FeedSettings) -> [Entity] {
        switch kind {
        case .keyword: return []
        case .journal: return s.followedJournals + s.mutedJournals
        case .author: return s.followedAuthors + s.mutedAuthors
        case .topic: return s.followedTopics + s.mutedTopics
        case .institution: return s.followedInstitutions
        case .funder: return s.followedFunders
        }
    }

    /// The thing as a level can be set on it: with the id the lists know it by where it is followed or muted, else
    /// the id the paper gives it. nil where there is no way to search for it (a topic with no OpenAlex id).
    static func ref(_ kind: FacetKind, name: String, paper: Paper, settings s: FeedSettings) -> FacetRef? {
        let wanted = name.lowercased()
        if kind == .keyword { return .keyword(name) }
        if let e = list(kind, in: s).first(where: { $0.name.lowercased() == wanted }) { return FacetRef(kind: kind, id: e.id, name: e.name) }
        switch kind {
        case .journal:
            if let id = paper.journalID, paper.journal?.lowercased() == wanted { return FacetRef(kind: kind, id: id, name: name) }
            return FacetRef(kind: kind, id: SourceRouting.namedID(name), name: name)
        case .author:
            if paper.authors.count == paper.authorIDs.count, let i = paper.authors.firstIndex(where: { $0.lowercased() == wanted }) {
                return FacetRef(kind: kind, id: paper.authorIDs[i], name: name)
            }
            return FacetRef(kind: kind, id: SourceRouting.namedID(name), name: name)
        case .topic:
            if paper.topics.count == paper.topicIDs.count, let i = paper.topics.firstIndex(where: { $0.lowercased() == wanted }) {
                return FacetRef(kind: kind, id: paper.topicIDs[i], name: name)
            }
            return nil
        case .institution, .funder:
            return nil
        case .keyword:
            return nil
        }
    }

    /// What the thumb could be about, the reasons the paper is in the feed first (the most specific first), then
    /// its journal, its first and last author, its own keywords and its topics. Each thing once.
    static func candidates(for paper: Paper, settings s: FeedSettings, limit: Int = 10) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ ref: FacetRef?) {
            guard let ref, out.count < limit, seen.insert(ref.key).inserted else { return }
            out.append(Candidate(ref: ref, level: s.level(of: ref)))
        }
        for tag in Why.tags(reasons: paper.reasons, followed: paper.followed) where !tag.detail.isEmpty {
            let kind: FacetKind?
            switch tag.kind {
            case .author: kind = .author
            case .keyword: kind = .keyword
            case .journal: kind = .journal
            case .institution: kind = .institution
            case .funder: kind = .funder
            case .followedTopic, .ownTopic: kind = .topic
            case .citesYou, .citesTracked, .other: kind = nil
            }
            if let kind { add(ref(kind, name: tag.detail, paper: paper, settings: s)) }
        }
        if let journal = paper.journal, !paper.isRepository { add(ref(.journal, name: journal, paper: paper, settings: s)) }
        for name in [paper.authors.first, paper.authors.last].compactMap({ $0 }) { add(ref(.author, name: name, paper: paper, settings: s)) }
        // The paper's own keywords, more specific than its topics.
        for name in (paper.keywords ?? []).prefix(3) { add(ref(.keyword, name: name, paper: paper, settings: s)) }
        for name in paper.topics.prefix(3) { add(ref(.topic, name: name, paper: paper, settings: s)) }
        return out
    }

    /// What is chosen to begin with: the first reason the paper is in the feed for, if it has one, which is the one
    /// the post itself names. One only: the thumb is about the best reason, not a handful, because with several
    /// people end up with the first and whatever else they touched on the way.
    static func preselected(_ candidates: [Candidate], paper: Paper) -> String? {
        let named = Why.tags(reasons: paper.reasons, followed: paper.followed).first { !$0.detail.isEmpty }
        guard let named else { return nil }
        let kind: FacetKind?
        switch named.kind {
        case .author: kind = .author
        case .keyword: kind = .keyword
        case .journal: kind = .journal
        case .institution: kind = .institution
        case .funder: kind = .funder
        case .followedTopic, .ownTopic: kind = .topic
        default: kind = nil
        }
        guard let kind, let first = candidates.first(where: { $0.ref.kind == kind && $0.ref.name.lowercased() == named.detail.lowercased() }) else { return nil }
        return first.ref.key
    }

    /// The thumb applied: each chosen thing moves one level, up or down. Returns what moved, for saying so.
    @discardableResult
    static func apply(_ chosen: [FacetRef], up: Bool, to s: inout FeedSettings) -> [(ref: FacetRef, from: Level, to: Level)] {
        chosen.map { ref in
            let before = s.level(of: ref)
            s.step(ref, by: up ? 1 : -1)
            return (ref, before, s.level(of: ref))
        }
    }

    /// One line that says what a thumb did to the levels.
    static func summary(_ moved: [(ref: FacetRef, from: Level, to: Level)]) -> String {
        let changed = moved.filter { $0.from != $0.to }
        guard !changed.isEmpty else { return moved.isEmpty ? "" : "Levels unchanged: they are at the limit." }
        return changed.prefix(3).map { "“\($0.ref.name)” \($0.from.title) → \($0.to.title)" }.joined(separator: ", ")
            + (changed.count > 3 ? " and \(changed.count - 3) more" : "")
    }
}
