import Foundation

// Starting again, all of it or by parts. The backup is how to go back to what was; this is how to begin from
// nothing, or from nothing for only some of it: forget what is followed but keep the sliders, or the thumbs but
// not the reading list. A part says what it clears and what it leaves. What is kept on one device only
// (recent searches, pasted projects, what was read) is cleared by the app; the keys and the connection to a
// sync file are never touched. Pure and tested.

enum ResetPart: String, CaseIterable, Identifiable {
    case you, follows, thumbs, lists, ranking, sources, references, searches, projects, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .you: return "You"
        case .follows: return "What you follow and mute"
        case .thumbs: return "What your thumbs taught"
        case .lists: return "Reading list, For me and hidden papers"
        case .ranking: return "Ranking and what the feed shows"
        case .sources: return "Sources"
        case .references: return "Reference managers"
        case .searches: return "Recent searches"
        case .projects: return "Your projects"
        case .history: return "What you have read"
        }
    }

    /// What it clears, in a line.
    var clears: String {
        switch self {
        case .you: return "Your ORCID iD, the people you also learn from, and whether your own papers count."
        case .follows: return "Topics, journals, researchers, institutions, funders and keywords followed or muted, tracked papers and the levels set by hand. They are filled in again from your publications the next time the feed is built, as on a first launch."
        case .thumbs: return "Every thumb on a keyword, journal, researcher or topic, how they fade and pull, and how much papers you kept or hid count."
        case .lists: return "The papers on your reading list, marked For me or hidden, and what the hidden ones taught."
        case .ranking: return "The sliders, the kinds of paper, how far back to look, the filters and the order of the feed."
        case .sources: return "Which sources are on (OpenAlex, Europe PMC, Crossref, arXiv, OSF), not the OpenAlex key."
        case .references: return "Which reference managers you use and the Zotero and library file switches, not the Zotero key."
        case .searches: return "The searches you agreed to count toward the feed."
        case .projects: return "The project descriptions you pasted."
        case .history: return "Which papers were seen and read, so every paper in the feed is new again."
        }
    }

    /// Kept on this device only, so the app clears it and it is not in the settings.
    var onThisDeviceOnly: Bool { self == .searches || self == .projects }

    /// Whether the settings file holds it, and so another device sharing the sync file will follow the reset.
    var inSettings: Bool { !(self == .searches || self == .projects || self == .history) }

    /// How much there is to clear, for the screen. Nil for what only the app knows.
    func detail(in s: FeedSettings) -> String? {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 0 ? "Nothing to clear" : "\(count) \(count == 1 ? one : many)" }
        switch self {
        case .you: return (s.orcid ?? "").isEmpty && s.profileOrcids.isEmpty ? "Nothing to clear" : "ORCID iD set"
        case .follows:
            let count = s.followedTopics.count + s.followedJournals.count + s.followedAuthors.count + s.followedInstitutions.count
                + s.followedFunders.count + s.followedKeywords.count + s.trackedPapers.count + s.mutedJournals.count
                + s.mutedAuthors.count + s.mutedTopics.count + s.mutedKeywords.count + s.levels.count
            return n(count, "follow, mute or level", "follows, mutes and levels")
        case .thumbs: return n(s.thumbEvents.count, "thumb", "thumbs")
        case .lists: return n(s.feedback.saved.count + s.feedback.liked.count + s.feedback.hidden.count, "paper", "papers")
        case .ranking, .sources, .references, .searches, .projects, .history: return nil
        }
    }
}

extension FeedSettings {
    /// The settings with `parts` back to what a first launch has, and everything else as it was.
    /// (A part held only on the device is the app's to clear.)
    mutating func reset(_ parts: Set<ResetPart>) {
        let d = FeedSettings()
        if parts.contains(.you) {
            orcid = d.orcid; profileOrcids = d.profileOrcids; useMyPublications = d.useMyPublications
        }
        if parts.contains(.follows) {
            followedTopics = d.followedTopics; followedJournals = d.followedJournals; followedAuthors = d.followedAuthors
            followedInstitutions = d.followedInstitutions; followedFunders = d.followedFunders; followedKeywords = d.followedKeywords
            trackedPapers = d.trackedPapers
            mutedJournals = d.mutedJournals; mutedAuthors = d.mutedAuthors; mutedTopics = d.mutedTopics; mutedKeywords = d.mutedKeywords
            levels = d.levels
            // So that the follow lists are filled from the publications again, as on a first launch.
            profileFilled = d.profileFilled
        }
        if parts.contains(.thumbs) {
            thumbEvents = d.thumbEvents; evidence = d.evidence; asksThumbBasis = d.asksThumbBasis
            hideMemory = d.hideMemory; hideHalfLifeMonths = d.hideHalfLifeMonths; likeMemory = d.likeMemory
            likeHalfLifeMonths = d.likeHalfLifeMonths; hideStrength = d.hideStrength; likeStrength = d.likeStrength
        }
        if parts.contains(.lists) { feedback = d.feedback }
        if parts.contains(.ranking) {
            kindWeights = d.kindWeights; daysBack = d.daysBack; recency = d.recency; closeness = d.closeness
            impactWeight = d.impactWeight; authorWeight = d.authorWeight; byline = d.byline
            feedOrder = d.feedOrder; highlightCount = d.highlightCount; highlightCloseness = d.highlightCloseness
            highlightImpact = d.highlightImpact; highlightAuthorH = d.highlightAuthorH
            requireAbstract = d.requireAbstract; openAccessOnly = d.openAccessOnly; seenExpiryDays = d.seenExpiryDays
            showReadPapers = d.showReadPapers; languages = d.languages; dwellSeconds = d.dwellSeconds
            countsSearches = d.countsSearches; asksAboutSearches = d.asksAboutSearches
        }
        if parts.contains(.sources) {
            useOpenAlex = d.useOpenAlex; useEuropePMC = d.useEuropePMC; useCrossref = d.useCrossref
            useArXiv = d.useArXiv; useOSF = d.useOSF
        }
        if parts.contains(.references) {
            referenceManagers = d.referenceManagers; useZotero = d.useZotero; useLibraryFile = d.useLibraryFile
            zoteroRecent = d.zoteroRecent
        }
    }
}
