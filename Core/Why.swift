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

    private static func describe(_ reason: String, followed: Bool) -> (rank: Int, text: String, symbol: String) {
        func after(_ prefix: String) -> String? {
            reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : nil
        }
        if reason == "Cites your work" { return (0, "Cites your work", "quote.bubble") }
        if let title = after("Cites: ") { return (1, "Cites a paper you track: \(title)", "quote.bubble") }
        if let name = after("Author: ") { return (2, "Author you follow: \(name)", "person") }
        if let name = after("Keyword: ") { return (3, "Keyword you follow: \(name)", "magnifyingglass") }
        if after("Journal: ") != nil { return (4, "From a journal you follow", "newspaper") }
        if let name = after("Institution: ") { return (5, "Institution you follow: \(name)", "building.columns") }
        if let name = after("Funder: ") { return (6, "Funder you follow: \(name)", "banknote") }
        if let name = after("Topic: ") {
            // A followed topic and one inferred from the user's own papers read alike
            // in the reasons; the paper's `followed` flag says which.
            return followed ? (7, "Topic you follow: \(name)", "tag")
                            : (8, "Topic from your own papers: \(name)", "person.text.rectangle")
        }
        return (9, reason, fallbackSymbol)
    }
}
