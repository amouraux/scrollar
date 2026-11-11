import Foundation

// What a new user sees on an empty feed: the few things that make the first feed useful, each with
// the Tune screen that does it. Pure, so that what is offered and when is tested; the screen only draws it.

struct FirstRunStep: Equatable, Identifiable {
    /// The Tune screen that does it; the raw values are those of `TuneScreen`.
    enum Target: String { case you, follow, sources, references }

    var id: String { title }
    var title: String
    var detail: String
    var target: Target
    var done: Bool
    /// Not needed for a first feed.
    var optional: Bool
}

enum FirstRun {
    /// Whether anything is followed, which a feed can be built from as well as an ORCID iD can.
    static func hasFollows(_ s: FeedSettings) -> Bool {
        !(s.followedTopics.isEmpty && s.followedJournals.isEmpty && s.followedAuthors.isEmpty
          && s.followedInstitutions.isEmpty && s.followedFunders.isEmpty && s.followedKeywords.isEmpty)
    }

    static func hasPublications(_ s: FeedSettings) -> Bool {
        s.orcid.flatMap(Orcid.normalised) != nil || !s.profileOrcids.isEmpty
    }

    /// What is left to do before the feed is useful, then what would make it better. A step stays
    /// listed, ticked, once done, so the list reads as progress and not as a changing menu.
    static func steps(settings s: FeedSettings, hasOpenAlexKey: Bool, hasReferenceLibrary: Bool) -> [FirstRunStep] {
        var out = [
            FirstRunStep(title: "Add your ORCID iD",
                         detail: "Type your name and pick yourself from the list. The feed learns what you work on from your papers.",
                         target: .you, done: hasPublications(s), optional: false),
            FirstRunStep(title: "Or follow something",
                         detail: "A topic, a journal, a researcher or a keyword. Enough on its own if you have no ORCID iD.",
                         target: .follow, done: hasFollows(s), optional: false),
        ]
        if s.useOpenAlex {
            out.append(FirstRunStep(title: "Add a free OpenAlex key",
                                    detail: "Covers every field, not only biomedicine, and lets you follow researchers and topics by name.",
                                    target: .sources, done: hasOpenAlexKey, optional: true))
        }
        out.append(FirstRunStep(title: "Connect Zotero or another reference manager",
                                detail: "What you file there shows what you are reading now, and Add to Zotero saves a paper in one tap.",
                                target: .references, done: hasReferenceLibrary, optional: true))
        return out
    }
}
