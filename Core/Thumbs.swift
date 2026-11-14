import Foundation

// What a thumb is about. A paper has many things that could be why it is liked or not: a keyword that found
// it, its journal, its authors, its topics. Asking which makes the effect of a thumb something the user chose
// and can see: the one thing picked, the best reason, is recorded as a thumb on it (see Evidence.swift). Pure and
// tested; the question is a menu on the thumb button.

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

/// Where a reason comes from, for grouping the menu.
enum ThumbGroup: Int, Hashable {
    case why, journal, author, institution, keyword, title, topic

    var heading: String {
        switch self {
        case .why: return "Why it is in your feed"
        case .journal: return "Journal"
        case .author: return "Researchers"
        case .institution: return "Institutions"
        case .keyword: return "Keywords"
        case .title: return "Phrases in the title"
        case .topic: return "Topics"
        }
    }
}

enum ThumbBasis {
    struct Candidate: Hashable {
        var ref: FacetRef
        /// The level it has now.
        var level: Level
        var group: ThumbGroup = .topic
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
        case .institution:
            // Named by what the paper says: enough to rank by, not to search for.
            return FacetRef(kind: kind, id: SourceRouting.namedID(name), name: name)
        case .funder, .keyword:
            return nil
        }
    }

    /// What the thumb could be about: the reasons the paper is in the feed (the most specific first), then its journal,
    /// its researchers (first, last and up to two others), the institutions of the first and last, its own keywords
    /// (up to five), the phrases of its title (up to three, for the many papers whose source gives no keywords) and
    /// its topics (up to five). Each thing once.
    static func candidates(for paper: Paper, settings s: FeedSettings, limit: Int = 18) -> [Candidate] {
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ ref: FacetRef?, _ group: ThumbGroup) {
            guard let ref, out.count < limit, seen.insert(ref.key).inserted else { return }
            out.append(Candidate(ref: ref, level: s.level(of: ref), group: group))
        }
        for tag in Why.tags(reasons: paper.reasons, followed: paper.followed) where !tag.detail.isEmpty {
            if let kind = facetKind(tag.kind) { add(ref(kind, name: tag.detail, paper: paper, settings: s), .why) }
        }
        if let journal = paper.journal, !paper.isRepository { add(ref(.journal, name: journal, paper: paper, settings: s), .journal) }
        // First, last, then the others nearest the ends: the first and last are usually who the work is by.
        let a = paper.authors
        var order: [String] = []
        for i in [0, a.count - 1, 1, a.count - 2] where a.indices.contains(i) && !order.contains(a[i]) { order.append(a[i]) }
        for name in order { add(ref(.author, name: name, paper: paper, settings: s), .author) }
        for name in [paper.firstInstitution, paper.lastInstitution].compactMap({ $0 }) {
            add(ref(.institution, name: name, paper: paper, settings: s), .institution)
        }
        // The paper's own keywords, more specific than its topics.
        for name in (paper.keywords ?? []).prefix(5) { add(ref(.keyword, name: name, paper: paper, settings: s), .keyword) }
        for name in TitleTerms.phrases(from: paper.title, limit: 3) { add(ref(.keyword, name: name, paper: paper, settings: s), .title) }
        for name in paper.topics.prefix(5) { add(ref(.topic, name: name, paper: paper, settings: s), .topic) }
        return out
    }

    /// The kind of thing a reason names, for those a thumb can be about: not a citation, nor an unknown reason.
    static func facetKind(_ kind: Why.Kind) -> FacetKind? {
        switch kind {
        case .author: return .author
        case .keyword: return .keyword
        case .journal: return .journal
        case .institution: return .institution
        case .funder: return .funder
        case .followedTopic, .ownTopic: return .topic
        case .citesYou, .citesTracked, .project, .other: return nil
        }
    }

    /// What is chosen to begin with: the first reason the paper is in the feed for, if it has one, which is the one
    /// the post itself names. One only: the thumb is about the best reason, not a handful, because with several
    /// people end up with the first and whatever else they touched on the way.
    static func preselected(_ candidates: [Candidate], paper: Paper) -> String? {
        let named = Why.tags(reasons: paper.reasons, followed: paper.followed).first { !$0.detail.isEmpty }
        guard let named, let kind = facetKind(named.kind), let first = candidates.first(where: { $0.ref.kind == kind && $0.ref.name.lowercased() == named.detail.lowercased() }) else { return nil }
        return first.ref.key
    }
}
