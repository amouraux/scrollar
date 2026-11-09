import Foundation

// A level for each thing the user follows or mutes, instead of only follow or mute: how hard the feed
// should lean toward or away from a keyword, a journal, an author, a topic. Five steps, so that "promote"
// can be mild or complete. The follow and mute lists stay what they were (and give each thing its starting
// level); a level the user sets is an override kept beside them. With no override anywhere the feed is
// exactly what it was. Pure and tested; the screens are elsewhere.

enum Level: Int, Codable, CaseIterable, Comparable {
    case hide = -2, lower = -1, normal = 0, higher = 1, maximum = 2

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .hide: return "Hide"
        case .lower: return "Lower"
        case .normal: return "Normal"
        case .higher: return "Higher"
        case .maximum: return "Maximum"
        }
    }

    /// What it means, in a few words.
    var summary: String {
        switch self {
        case .hide: return "Papers about it are removed."
        case .lower: return "Papers about it rank lower."
        case .normal: return "No effect."
        case .higher: return "It is searched for, and papers about it rank higher."
        case .maximum: return "It is searched for, and everything about it is kept and ranks higher."
        }
    }

    /// Added to the score of a paper that carries it. Maximum's is on top of the 0.8 a followed paper already gets,
    /// so that it ranks above Higher; what sets it apart is that nothing about it is cut.
    var bonus: Double {
        switch self {
        case .hide: return 0
        case .lower: return -0.6
        case .normal: return 0
        case .higher: return 0.8
        case .maximum: return 0.4
        }
    }

    /// Whether the feed asks the sources for it.
    var fetches: Bool { self >= .higher }

    /// Whether everything it finds is kept, however low it scores.
    var pins: Bool { self == .maximum }
}

enum FacetKind: String, Codable, CaseIterable {
    case keyword, journal, author, topic, institution, funder

    var title: String {
        switch self {
        case .keyword: return "Keywords"
        case .journal: return "Journals"
        case .author: return "Researchers"
        case .topic: return "Topics"
        case .institution: return "Institutions"
        case .funder: return "Funders"
        }
    }

    /// A topic, an institution or a funder names hundreds of papers a month, in every field: it can be raised
    /// but not kept in full, as a follow of one never was.
    var isBroad: Bool { self == .topic || self == .institution || self == .funder }

    /// The levels it may be given.
    var levels: [Level] { isBroad ? [.hide, .lower, .normal, .higher] : Level.allCases }

    /// How a paper's reasons name it.
    var reasonPrefix: String {
        switch self {
        case .keyword: return "Keyword: "
        case .journal: return "Journal: "
        case .author: return "Author: "
        case .topic: return "Topic: "
        case .institution: return "Institution: "
        case .funder: return "Funder: "
        }
    }
}

/// One thing a level can be set on. `id` is what identifies it (a keyword's phrase in lower case, an OpenAlex id,
/// or "name:…" for what was added by name); `name` is what to call it.
struct FacetRef: Hashable {
    var kind: FacetKind
    var id: String
    var name: String

    var key: String { kind.rawValue + "/" + id.lowercased() }

    /// How the papers that this was searched for carry it in their reasons.
    var reason: String { kind.reasonPrefix + name }

    static func keyword(_ phrase: String) -> FacetRef { FacetRef(kind: .keyword, id: phrase.lowercased(), name: phrase) }
}

/// A level the user set, which overrides the one the follow and mute lists give.
struct LevelEntry: Codable, Hashable {
    var kind: FacetKind
    var id: String
    var name: String
    var level: Level

    var ref: FacetRef { FacetRef(kind: kind, id: id, name: name) }
    var key: String { ref.key }

    /// Whether a paper is about it. By what the paper itself says where that is known (its journal, its authors, its
    /// topics, its words), and by the reasons it is in the feed for, which also name institutions and funders.
    func matches(_ paper: Paper, text: String? = nil) -> Bool {
        let wanted = name.lowercased()
        let lid = id.lowercased()
        let plain = SourceRouting.isNamed(id) ? String(id.dropFirst(5)).lowercased() : wanted
        if paper.reasons.contains(ref.reason) { return true }
        switch kind {
        case .keyword:
            return (text ?? (paper.title + " " + (paper.abstract ?? "")).lowercased()).contains(lid)
        case .journal:
            return paper.journalID?.lowercased() == lid || paper.journal?.lowercased() == plain
        case .author:
            return paper.authorIDs.contains { $0.lowercased() == lid } || paper.authors.contains { $0.lowercased() == plain }
        case .topic:
            return paper.topicIDs.contains { $0.lowercased() == lid } || paper.topics.contains { $0.lowercased() == plain }
        case .institution:
            return [paper.firstInstitution, paper.lastInstitution].contains { $0?.lowercased() == plain }
        case .funder:
            return false
        }
    }
}

extension FeedSettings {
    /// The level a thing has before the user sets one: what the lists give it.
    func defaultLevel(_ f: FacetRef) -> Level {
        let id = f.id.lowercased()
        func listed(_ entities: [Entity]) -> Bool { entities.contains { $0.id.lowercased() == id } }
        switch f.kind {
        case .keyword:
            if followedKeywords.contains(where: { $0.phrase.lowercased() == id }) { return .maximum }
            return mutedKeywords.contains { $0.lowercased() == id } ? .hide : .normal
        case .journal:
            return listed(followedJournals) ? .maximum : (listed(mutedJournals) ? .hide : .normal)
        case .author:
            return listed(followedAuthors) ? .maximum : (listed(mutedAuthors) ? .hide : .normal)
        case .topic:
            return listed(followedTopics) ? .higher : (listed(mutedTopics) ? .hide : .normal)
        case .institution:
            return listed(followedInstitutions) ? .higher : .normal
        case .funder:
            return listed(followedFunders) ? .higher : .normal
        }
    }

    /// The level the user set, if one was.
    func override(_ f: FacetRef) -> Level? { levels.first { $0.key == f.key }?.level }

    /// What the feed acts on: the user's level, or the one the lists give.
    func level(of f: FacetRef) -> Level { override(f) ?? defaultLevel(f) }

    /// Set a level. One equal to the starting level is no override, so the lists stay the whole story where nothing was changed.
    mutating func setLevel(_ level: Level, for f: FacetRef) {
        levels.removeAll { $0.key == f.key }
        let allowed = f.kind.levels
        let chosen = allowed.contains(level) ? level : (allowed.last ?? .normal)
        if chosen != defaultLevel(f) { levels.append(LevelEntry(kind: f.kind, id: f.id, name: f.name, level: chosen)) }
    }

    /// One step up or down, within what the kind allows; the step is taken from the level it has now.
    mutating func step(_ f: FacetRef, by delta: Int) {
        let allowed = f.kind.levels
        let now = level(of: f)
        guard let i = allowed.firstIndex(of: now) ?? allowed.firstIndex(where: { $0 >= now }) else { return }
        let next = allowed[min(max(i + delta, 0), allowed.count - 1)]
        setLevel(next, for: f)
    }

    /// Every thing that has a level: what is followed or muted, and what the user set one on, each with the level it has.
    func facets() -> [(ref: FacetRef, level: Level, isOverride: Bool)] {
        var refs: [FacetRef] = []
        func add(_ kind: FacetKind, _ list: [Entity]) { refs += list.map { FacetRef(kind: kind, id: $0.id.lowercased() == $0.id ? $0.id : $0.id, name: $0.name) } }
        refs += followedKeywords.map { FacetRef.keyword($0.phrase) }
        refs += mutedKeywords.map { FacetRef.keyword($0) }
        add(.journal, followedJournals); add(.journal, mutedJournals)
        add(.author, followedAuthors); add(.author, mutedAuthors)
        add(.topic, followedTopics); add(.topic, mutedTopics)
        add(.institution, followedInstitutions)
        add(.funder, followedFunders)
        refs += levels.map(\.ref)
        var seen = Set<String>()
        return refs.filter { seen.insert($0.key).inserted }.map { ($0, level(of: $0), override($0) != nil) }
            .sorted { a, b in
                a.ref.kind != b.ref.kind ? FacetKind.allCases.firstIndex(of: a.ref.kind)! < FacetKind.allCases.firstIndex(of: b.ref.kind)!
                    : a.ref.name.localizedCaseInsensitiveCompare(b.ref.name) == .orderedAscending
            }
    }
}
