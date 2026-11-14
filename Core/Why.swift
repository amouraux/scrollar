import Foundation

/// The one reason to show above a post: why it is in the feed. A paper can be
/// found by several seeds (a journal you follow, a topic of your own, a citation
/// of your work); the most specific choice of the user's wins, since that is the
/// one they can act on.
///
/// The reasons are the strings `Seed.reason` writes, so this reads their prefixes;
/// a test ties the two together, so renaming one without the other fails.
struct Why: Equatable {
    var text: String
    var symbol: String
    /// Other reasons the paper also has, shown in full when the post is opened.
    var others: Int
    /// It cites the user's work or a paper they track: worth standing out.
    var isCitation: Bool

    static let fallbackSymbol = "arrow.turn.down.right"

    static func main(for paper: Paper) -> Why? {
        guard !paper.reasons.isEmpty else { return nil }
        let described = paper.reasons.map { describe($0, followed: paper.followed) }
        // min(by:) keeps the first of equals, so seed order breaks a tie.
        guard let best = described.min(by: { $0.rank < $1.rank }) else { return nil }
        return Why(text: best.text, symbol: best.symbol, others: described.count - 1, isCitation: best.rank <= 1)
    }

    /// Every reason the paper has, the user's most specific first, for the reader pane, which has
    /// room to say all of them where a post shows one.
    static func all(for paper: Paper) -> [Why] {
        paper.reasons
            .map { describe($0, followed: paper.followed) }
            .enumerated()
            .sorted { $0.element.rank != $1.element.rank ? $0.element.rank < $1.element.rank : $0.offset < $1.offset }
            .map { Why(text: $0.element.text, symbol: $0.element.symbol, others: 0, isCitation: $0.element.rank <= 1) }
    }

    /// The kinds of reason, in the order the user's own choices outrank one another. The raw value
    /// is the rank, so sorting by it puts the most specific first.
    enum Kind: Int, CaseIterable, Comparable {
        case citesYou, citesTracked, author, keyword, journal, institution, funder, followedTopic, ownTopic, project, other

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// A heading for a group of papers that share it (the filter panel).
        var title: String {
            switch self {
            case .citesYou: return "Cites your work"
            case .citesTracked: return "Cites a paper you track"
            case .author: return "Author you follow"
            case .keyword: return "Keyword you follow"
            case .journal: return "Journal you follow"
            case .institution: return "Institution you follow"
            case .funder: return "Funder you follow"
            case .followedTopic: return "Topic you follow"
            case .ownTopic: return "Topic from your own papers"
            case .project: return "From your project"
            case .other: return "Other"
            }
        }

        var symbol: String {
            switch self {
            case .citesYou, .citesTracked: return "quote.bubble"
            case .author: return "person"
            case .keyword: return "magnifyingglass"
            case .journal: return "newspaper"
            case .institution: return "building.columns"
            case .funder: return "banknote"
            case .followedTopic: return "tag"
            case .ownTopic: return "person.text.rectangle"
            case .project: return "doc.text"
            case .other: return fallbackSymbol
            }
        }
    }

    /// One reason, taken apart: what kind it is and the name it carries (the author, the topic, the
    /// tracked paper's title; empty for "Cites your work"). Two papers found for the same name share a tag.
    struct Tag: Hashable {
        var kind: Kind
        var detail: String
    }

    /// The reasons as tags, most specific first, a paper's own order breaking a tie.
    static func tags(reasons: [String], followed: Bool) -> [Tag] {
        let tags = reasons.map { tag($0, followed: followed) }
        // Sorted by rank alone and stable, so a paper's own order breaks a tie.
        return tags.enumerated().sorted { l, r in
            l.element.kind == r.element.kind ? l.offset < r.offset : l.element.kind < r.element.kind
        }.map { $0.element }
    }

    static func tag(_ reason: String, followed: Bool) -> Tag {
        func after(_ prefix: String) -> String? {
            reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : nil
        }
        if reason == "Cites your work" { return Tag(kind: .citesYou, detail: "") }
        if let title = after("Cites: ") { return Tag(kind: .citesTracked, detail: title) }
        if let name = after("Author: ") { return Tag(kind: .author, detail: name) }
        if let name = after("Keyword: ") { return Tag(kind: .keyword, detail: name) }
        if let name = after("Journal: ") { return Tag(kind: .journal, detail: name) }
        if let name = after("Institution: ") { return Tag(kind: .institution, detail: name) }
        if let name = after("Funder: ") { return Tag(kind: .funder, detail: name) }
        if let name = after("Project: ") { return Tag(kind: .project, detail: name) }
        if let name = after("Topic: ") {
            // A followed topic and one inferred from the user's own papers read alike
            // in the reasons; the paper's `followed` flag says which.
            return Tag(kind: followed ? .followedTopic : .ownTopic, detail: name)
        }
        return Tag(kind: .other, detail: reason)
    }

    /// The sentence a post or a saved row says for a tag.
    static func text(for tag: Tag) -> String {
        switch tag.kind {
        case .citesYou: return "Cites your work"
        case .citesTracked: return "Cites a paper you track: \(tag.detail)"
        case .journal: return "From a journal you follow"
        case .other: return tag.detail
        default: return "\(tag.kind.title): \(tag.detail)"
        }
    }

    private static func describe(_ reason: String, followed: Bool) -> (rank: Int, text: String, symbol: String) {
        let t = tag(reason, followed: followed)
        return (t.kind.rawValue, text(for: t), t.kind.symbol)
    }
}
