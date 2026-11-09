import Foundation

// Everything the user can enter to shape the feed lives in FeedSettings, and
// nothing else decides what appears. Foundation only, so it is tested like the
// rest of the core.
//
// The file format rule is DayHand's: every decoder is hand-written and tolerant.
// A missing key takes its default, an unknown key is ignored, and a wrongly
// typed value falls back to its default instead of failing the whole file. A
// settings file that threw away the user's follows on one typo would be worse
// than one that ignored the typo. Only JSON that is not JSON at all throws, so
// the caller can say so instead of quietly starting from scratch.

/// A thing on OpenAlex the user picked from a list: the short id is what is
/// stored and queried, the name is only what to show.
struct Entity: Codable, Hashable {
    var id: String
    var name: String
}

/// How the feed is ordered on screen.
enum FeedOrder: String, Codable, CaseIterable {
    /// One list, ordered by score, with a short strip of highlights above it. Everything a
    /// journal, researcher or keyword the user follows found stays in it, however low it scores.
    case blended
    /// Cited you, then what the user follows, then the ranked rest.
    case sections

    var title: String {
        switch self {
        case .blended: return "One ranked list"
        case .sections: return "In sections"
        }
    }
}

/// How much a followed keyword matters to the user: it moves the papers it finds up or down
/// the ranking, and decides their order under "From what you follow".
enum Importance: String, Codable, CaseIterable {
    case low, normal, high

    var title: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .high: return "High"
        }
    }

    /// Added to a paper's score. Normal is no change; the range is about that of the similarity term.
    var bonus: Double {
        switch self {
        case .low: return -0.6
        case .normal: return 0
        case .high: return 1.2
        }
    }

    /// Order under "From what you follow": high first.
    var tier: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        }
    }
}

struct KeywordRule: Codable, Hashable {
    var phrase: String
    /// Every one of these must appear in the title or abstract.
    var alsoRequire: [String] = []
    /// None of these may appear. "attention" without "deficit" is a different literature.
    var exclude: [String] = []
    var importance = Importance.normal
    /// What identifies this rule in the sync file. Not the phrase: the same phrase may carry
    /// several rules ("pain" with EEG, "pain" with MRI), and renaming one must not look like
    /// deleting it and adding another. A rule saved before this existed takes its phrase, which
    /// is the key it was already synced under.
    var id: String

    init(phrase: String, alsoRequire: [String] = [], exclude: [String] = [], importance: Importance = .normal, id: String? = nil) {
        self.id = id ?? phrase
        self.phrase = phrase
        self.alsoRequire = alsoRequire
        self.exclude = exclude
        self.importance = importance
    }

    enum CodingKeys: String, CodingKey { case phrase, alsoRequire, exclude, importance, id }

    /// Tolerant like every stored type: a keyword saved before importance existed is Normal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decode(String.self, forKey: .phrase)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? phrase
        alsoRequire = (try? c.decodeIfPresent([String].self, forKey: .alsoRequire)) ?? []
        exclude = (try? c.decodeIfPresent([String].self, forKey: .exclude)) ?? []
        importance = (try? c.decodeIfPresent(Importance.self, forKey: .importance)) ?? .normal
    }

    /// The search this rule stands for. Rules with the same phrase and the same required words
    /// share a seed and a reason; they differ only in what they exclude.
    var seed: Seed { .keyword(phrase, also: alsoRequire.filter { !$0.isEmpty }) }

    /// `text` is already lowercased.
    func accepts(_ text: String) -> Bool {
        alsoRequire.allSatisfy { text.contains($0.lowercased()) }
            && !exclude.contains { text.contains($0.lowercased()) }
    }
}

/// What to do with one kind of paper.
enum Weight: String, Codable, CaseIterable {
    case hide, lower, normal, boost

    /// Added to a paper's score. `hide` removes the paper before ranking, so its
    /// number here only matters if something ranks without filtering first.
    var adjustment: Double {
        switch self {
        case .hide: return -100
        case .lower: return -1.3
        case .normal: return 0
        case .boost: return 0.8
        }
    }
}

struct SavedPaper: Codable, Hashable {
    var id: String          // the paper's dedupeKey
    var title: String
    var abstract: String?
    var date: String
    /// What a reference manager needs and a saved paper used to drop. Optional, so entries saved
    /// before these existed still load, sync and export (with what they have). An older app that
    /// reads one simply ignores them.
    var authors: [String]?
    var journal: String?
    /// Why the paper was in the feed when it was kept, and whether the topic was one the user follows.
    /// Lets a list be filtered by what makes a paper relevant to the user. Optional for the same
    /// reason as the two above; `SavedFilter.enriched` fills them in from the feed for older entries.
    var reasons: [String]?
    var followed: Bool?
    /// When the user kept it (seconds since 1970); nil for what was kept before this was recorded,
    /// which counts as inside any age limit. Only the order says how recent such a paper is.
    var keptAt: Double?
    /// The user said not to count it, without deleting it.
    var ignored: Bool?

    init(_ p: Paper, at: Date? = nil) {
        keptAt = at?.timeIntervalSince1970
        id = p.dedupeKey
        title = p.title
        abstract = p.abstract
        date = p.date
        authors = p.authors.isEmpty ? nil : p.authors
        journal = p.journal
        reasons = p.reasons.isEmpty ? nil : p.reasons
        followed = p.reasons.isEmpty ? nil : p.followed
    }
}

extension SavedPaper {
    /// Saved papers are keyed by DOI or PMID, which is also how to reach them.
    var link: URL? {
        if id.hasPrefix("doi:") { return URL(string: "https://doi.org/" + id.dropFirst(4)) }
        if id.hasPrefix("pmid:") { return URL(string: "https://pubmed.ncbi.nlm.nih.gov/" + id.dropFirst(5)) }
        if id.hasPrefix("oa:") { return URL(string: "https://openalex.org/" + id.dropFirst(3)) }
        return nil
    }
}

/// What the user does with the feed teaches it more honestly than what they say.
struct Feedback: Codable, Equatable {
    /// Saved papers join the profile: more like these.
    var saved: [SavedPaper] = []
    /// "For me": papers the user said are the kind they want, without saving them (they may know them
    /// already). They join the profile as saved papers do, and leave the top of the feed.
    var liked: [SavedPaper] = []
    /// Hidden papers (dedupeKeys) never come back.
    var hidden: [String] = []
    /// What a paper said when it was hidden, kept from the time this was added, so a hide can teach the
    /// feed to lower similar papers. A paper hidden before then is only an id, and teaches nothing.
    var hiddenPapers: [SavedPaper] = []

    mutating func save(_ p: Paper, at: Date = Date()) {
        guard !saved.contains(where: { $0.id == p.dedupeKey }) else { return }
        saved.append(SavedPaper(p, at: at))
    }

    mutating func unsave(_ p: Paper) { saved.removeAll { $0.id == p.dedupeKey } }

    func isLiked(_ p: Paper) -> Bool { liked.contains { $0.id == p.dedupeKey } }

    mutating func like(_ p: Paper, at: Date = Date()) {
        guard !isLiked(p) else { return }
        liked.append(SavedPaper(p, at: at))
    }

    mutating func unlike(_ id: String) { liked.removeAll { $0.id == id } }

    mutating func hide(_ p: Paper, at: Date = Date()) {
        if !hidden.contains(p.dedupeKey) { hidden.append(p.dedupeKey) }
        if !hiddenPapers.contains(where: { $0.id == p.dedupeKey }) { hiddenPapers.append(SavedPaper(p, at: at)) }
    }

    mutating func unhide(_ p: Paper) { unhide(id: p.dedupeKey) }

    /// The paper may be shown again, and what it taught is forgotten.
    mutating func unhide(id: String) {
        hidden.removeAll { $0 == id }
        hiddenPapers.removeAll { $0.id == id }
    }

    /// Give the papers kept before dates were recorded today's date, so that they begin to fade from now.
    /// Only those with no date are touched. True if any was.
    @discardableResult
    mutating func stampUndated(_ at: Date) -> Bool {
        var changed = false
        func stamp(_ list: inout [SavedPaper]) {
            for i in list.indices where list[i].keptAt == nil {
                list[i].keptAt = at.timeIntervalSince1970
                changed = true
            }
        }
        stamp(&saved); stamp(&liked); stamp(&hiddenPapers)
        return changed
    }

    /// Stop counting a paper, or count it again, without deleting it.
    enum Kind { case saved, liked, hidden }

    mutating func setIgnored(_ ignored: Bool, id: String, in kind: Kind) {
        func mark(_ list: inout [SavedPaper]) {
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].ignored = ignored ? true : nil }
        }
        switch kind {
        case .saved: mark(&saved)
        case .liked: mark(&liked)
        case .hidden: mark(&hiddenPapers)
        }
    }
}

struct FeedSettings: Codable, Equatable {
    /// Raise for any change an older copy of the app would misread.
    static let currentFormat = 1
    var formatVersion = FeedSettings.currentFormat

    // MARK: You
    var orcid: String? = nil
    /// Others whose publications the feed also learns from: a supervisor, a group leader.
    /// At most three; most useful to a PhD student who has no papers yet.
    var profileOrcids: [ProfileSource] = []
    /// The follow lists have been filled from the publications once. Never done again
    /// on its own, so nothing the user removed comes back.
    var profileFilled = false
    /// Build the profile, the topic follows and the "cited you" section from
    /// the user's own papers. Off for someone with no publications yet.
    var useMyPublications = true

    // MARK: Sources
    /// OpenAlex needs the user's own free key; Europe PMC (which includes PubMed and
    /// the preprint servers) needs nothing. Either can be switched off.
    var useOpenAlex = true
    var useEuropePMC = true
    /// Crossref, asked only when OpenAlex is off (it is the keyless way outside biomedicine); arXiv, for
    /// physics, mathematics and computer science, off until the user wants it.
    var useCrossref = true
    var useArXiv = false
    /// The Open Science Framework's preprint servers (PsyArXiv, SocArXiv…), off until the user wants them.
    var useOSF = false

    // MARK: What the thumbs count for
    /// How many of the newest hides count (the newest counts fully, the oldest of them a quarter), and
    /// in how many months a hide's weight halves (0 for never). A hide teaches the feed to lower similar papers.
    var hideMemory = 100
    var hideHalfLifeMonths = 6
    /// The same for what the user added to the reading list or marked For me.
    var likeMemory = 200
    var likeHalfLifeMonths = 0
    /// How hard a hide pushes (0 is off, 1 about as hard as closeness to your work pulls), and how much
    /// the reading list and For me count beside the user's papers and library (1 is as counted so far).
    var hideStrength = 0.5
    var likeStrength = 1.0

    /// Learn what interests the user from the most recently added items of their Zotero library,
    /// as from the papers they save. The key is not a setting: it lives in the Keychain.
    var useZotero = false
    /// The same, from a RIS or BibTeX export of another manager (EndNote, Mendeley…) imported in Tune.
    var useLibraryFile = false
    /// How many of the newest items count. Old interests fade because the newest are what is read.
    var zoteroRecent = 100

    // MARK: Follow
    var followedTopics: [Entity] = []
    var followedJournals: [Entity] = []
    var followedAuthors: [Entity] = []
    var followedInstitutions: [Entity] = []
    var followedFunders: [Entity] = []
    var followedKeywords: [KeywordRule] = []
    /// Papers whose new citations the user wants to hear about.
    var trackedPapers: [Entity] = []
    // MARK: How the feed is laid out. Only display: changing any of these fetches and ranks nothing again.
    /// One list ordered by score, or the older three blocks.
    var feedOrder = FeedOrder.blended
    /// How many highlights to put above the feed (0 for none, at most 5).
    var highlightCount = 3
    /// A highlight must be this close to the user's own work, as a place among the candidates:
    /// 0.95 is the closest twentieth.
    var highlightCloseness = 0.95
    /// And have at least one of: a journal with this impact or more (0 ignores it), an author with
    /// this h-index or more (0 ignores it), a citation of the user's work, or a journal, researcher
    /// or keyword they follow behind it.
    var highlightImpact = 5.0
    var highlightAuthorH = 40
    /// Seconds on screen after which a post counts as studied: it sinks below the ones only glanced at
    /// and leaves the feed sooner. Display only, like the highlights.
    var dwellSeconds = 4.0

    // MARK: Mute
    var mutedJournals: [Entity] = []
    var mutedAuthors: [Entity] = []
    var mutedTopics: [Entity] = []
    var mutedKeywords: [String] = []

    // MARK: Kinds of paper, keyed by `PaperKind.rawValue`
    /// Absent means normal. Case reports and conference abstracts start lowered.
    var kindWeights: [String: Weight] = [
        PaperKind.caseReport.rawValue: .lower,
        PaperKind.conferenceAbstract.rawValue: .lower,
    ]

    // MARK: Time and balance
    var daysBack = 30
    /// 0 ignores age, 1 puts a strong premium on this week. 0.5 is the default.
    var recency = 0.5
    /// 0: show me what I follow, whatever it is. 1: show me what is closest to my own work.
    var closeness = 0.5
    /// 0 ignores the journal; 1 gives a strong premium to papers from journals
    /// with a high two-year mean citedness (see `Paper.journalImpact`).
    var impactWeight = 0.0
    /// 0 ignores who wrote it; 1 gives a strong premium to papers whose chosen
    /// author has a high h-index.
    var authorWeight = 0.0
    /// Which author(s) head a post, and so whose h-index counts when it is wanted:
    /// the last (senior) author, the first, or, for both, the higher of the two.
    var byline = BylineChoice.last

    // MARK: Content
    var requireAbstract = false
    var openAccessOnly = false
    /// A paper that was shown but not read drops out of the feed this many days
    /// after it was first shown.
    var seenExpiryDays = 7
    /// Show papers already read, dimmed, at the end of the feed.
    var showReadPapers = false
    /// ISO 639-1 codes. Empty means any. A paper with no detected language passes.
    var languages: [String] = []

    var feedback = Feedback()

    init() {}

    func weight(for kind: PaperKind) -> Weight { kindWeights[kind.rawValue] ?? .normal }

    /// The importance of the most important followed keyword that found this paper, or nil if
    /// no keyword did. A paper found by a high keyword and a low one counts as high.
    func keywordImportance(of paper: Paper) -> Importance? {
        let byReason = Dictionary(followedKeywords.map { ($0.seed.reason, $0.importance) },
                                  uniquingKeysWith: { $0.tier >= $1.tier ? $0 : $1 })
        return paper.reasons.compactMap { byReason[$0] }.max { $0.tier < $1.tier }
    }

    /// A new rule on `phrase`. It takes the phrase as its id unless something already has it,
    /// so two devices that add the same word at once agree; a second rule gets its own.
    mutating func addKeyword(_ phrase: String) {
        let taken = Set(followedKeywords.map(\.id))
        followedKeywords.append(KeywordRule(phrase: phrase, id: taken.contains(phrase) ? UUID().uuidString : phrase))
    }

    /// Everything except what the user did with the feed. Changing a follow or a
    /// filter means fetching again; hiding one paper does not.
    var withoutFeedback: FeedSettings {
        var s = self
        s.feedback = Feedback()
        return s
    }

    /// What decides which papers must be fetched. The sliders (and which author counts) only decide how
    /// the papers already held are ordered, so moving one needs a re-rank (an
    /// incremental refresh, seconds) and not a full rebuild (a minute).
    var forFetching: FeedSettings {
        var s = withoutFeedback
        let d = FeedSettings()
        s.recency = d.recency
        s.closeness = d.closeness
        s.impactWeight = d.impactWeight
        s.authorWeight = d.authorWeight
        s.byline = d.byline
        s.feedOrder = d.feedOrder
        s.highlightCount = d.highlightCount
        s.highlightCloseness = d.highlightCloseness
        s.highlightImpact = d.highlightImpact
        s.highlightAuthorH = d.highlightAuthorH
        s.dwellSeconds = d.dwellSeconds
        s.profileFilled = d.profileFilled
        s.hideMemory = d.hideMemory
        s.hideHalfLifeMonths = d.hideHalfLifeMonths
        s.likeMemory = d.likeMemory
        s.likeHalfLifeMonths = d.likeHalfLifeMonths
        s.hideStrength = d.hideStrength
        s.likeStrength = d.likeStrength
        // The library only changes how what is held is ranked, like a slider.
        s.useZotero = d.useZotero
        s.useLibraryFile = d.useLibraryFile
        s.zoteroRecent = d.zoteroRecent
        return s
    }

    /// What the feed's contents and order depend on. Which author heads a post is
    /// only a matter of display until the h-index is asked to count, so until then
    /// changing it must not trigger a refresh.
    var forRanking: FeedSettings {
        var s = withoutFeedback
        if s.authorWeight == 0 { s.byline = FeedSettings().byline }
        let d = FeedSettings()
        s.feedOrder = d.feedOrder
        s.highlightCount = d.highlightCount
        s.highlightCloseness = d.highlightCloseness
        s.highlightImpact = d.highlightImpact
        s.highlightAuthorH = d.highlightAuthorH
        s.dwellSeconds = d.dwellSeconds
        s.profileFilled = d.profileFilled
        return s
    }

    mutating func setWeight(_ weight: Weight, for kind: PaperKind) {
        kindWeights[kind.rawValue] = weight
    }

    // MARK: Files

    static func decode(_ data: Data) throws -> FeedSettings {
        try JSONDecoder().decode(FeedSettings.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Tolerant decoding

extension Weight {
    /// A typo ("lowr") means normal, not a broken file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Weight(rawValue: raw) ?? .normal
    }
}

extension Feedback {
    enum CodingKeys: String, CodingKey { case saved, hidden, liked, hiddenPapers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = (try? c.decodeIfPresent([SavedPaper].self, forKey: .saved)) ?? []
        liked = (try? c.decodeIfPresent([SavedPaper].self, forKey: .liked)) ?? []
        hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? []
        hiddenPapers = (try? c.decodeIfPresent([SavedPaper].self, forKey: .hiddenPapers)) ?? []
    }
}

extension FeedSettings {
    enum CodingKeys: String, CodingKey {
        case formatVersion, orcid, profileOrcids, profileFilled, useMyPublications, useOpenAlex, useEuropePMC
        case hideMemory, hideHalfLifeMonths, likeMemory, likeHalfLifeMonths, hideStrength, likeStrength
        case useCrossref, useArXiv, useOSF
        case useZotero, useLibraryFile, zoteroRecent
        case followedTopics, followedJournals, followedAuthors, followedInstitutions
        case followedFunders, followedKeywords, trackedPapers, feedOrder, highlightCount, highlightCloseness, highlightImpact, highlightAuthorH, dwellSeconds
        case mutedJournals, mutedAuthors, mutedTopics, mutedKeywords
        case kindWeights, daysBack, recency, closeness, impactWeight, authorWeight, byline
        case requireAbstract, openAccessOnly, seenExpiryDays, showReadPapers, languages, feedback
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        formatVersion = get(.formatVersion, formatVersion)
        orcid = get(.orcid, orcid)
        profileOrcids = Array(get(.profileOrcids, profileOrcids).prefix(3))
        profileFilled = get(.profileFilled, profileFilled)
        useMyPublications = get(.useMyPublications, useMyPublications)
        useOpenAlex = get(.useOpenAlex, useOpenAlex)
        useEuropePMC = get(.useEuropePMC, useEuropePMC)
        useCrossref = get(.useCrossref, useCrossref)
        useArXiv = get(.useArXiv, useArXiv)
        useOSF = get(.useOSF, useOSF)
        hideMemory = min(max(get(.hideMemory, hideMemory), 10), 500)
        hideHalfLifeMonths = min(max(get(.hideHalfLifeMonths, hideHalfLifeMonths), 0), 36)
        likeMemory = min(max(get(.likeMemory, likeMemory), 20), 1000)
        likeHalfLifeMonths = min(max(get(.likeHalfLifeMonths, likeHalfLifeMonths), 0), 36)
        hideStrength = min(max(get(.hideStrength, hideStrength), 0), 1)
        likeStrength = min(max(get(.likeStrength, likeStrength), 0), 1)
        useZotero = get(.useZotero, useZotero)
        useLibraryFile = get(.useLibraryFile, useLibraryFile)
        zoteroRecent = min(max(get(.zoteroRecent, zoteroRecent), 10), 500)
        followedTopics = get(.followedTopics, followedTopics)
        followedJournals = get(.followedJournals, followedJournals)
        followedAuthors = get(.followedAuthors, followedAuthors)
        followedInstitutions = get(.followedInstitutions, followedInstitutions)
        followedFunders = get(.followedFunders, followedFunders)
        followedKeywords = get(.followedKeywords, followedKeywords)
        trackedPapers = get(.trackedPapers, trackedPapers)
        feedOrder = get(.feedOrder, feedOrder)
        highlightCount = min(max(get(.highlightCount, highlightCount), 0), 5)
        highlightCloseness = min(max(get(.highlightCloseness, highlightCloseness), 0.5), 1)
        highlightImpact = min(max(get(.highlightImpact, highlightImpact), 0), 50)
        highlightAuthorH = min(max(get(.highlightAuthorH, highlightAuthorH), 0), 200)
        dwellSeconds = min(max(get(.dwellSeconds, dwellSeconds), 2), 15)
        mutedJournals = get(.mutedJournals, mutedJournals)
        mutedAuthors = get(.mutedAuthors, mutedAuthors)
        mutedTopics = get(.mutedTopics, mutedTopics)
        mutedKeywords = get(.mutedKeywords, mutedKeywords)
        kindWeights = get(.kindWeights, kindWeights)
        daysBack = min(max(get(.daysBack, daysBack), 1), 365)
        recency = min(max(get(.recency, recency), 0), 1)
        closeness = min(max(get(.closeness, closeness), 0), 1)
        impactWeight = min(max(get(.impactWeight, impactWeight), 0), 1)
        authorWeight = min(max(get(.authorWeight, authorWeight), 0), 1)
        byline = get(.byline, byline)
        requireAbstract = get(.requireAbstract, requireAbstract)
        openAccessOnly = get(.openAccessOnly, openAccessOnly)
        seenExpiryDays = min(max(get(.seenExpiryDays, seenExpiryDays), 1), 60)
        showReadPapers = get(.showReadPapers, showReadPapers)
        languages = get(.languages, languages)
        feedback = get(.feedback, feedback)
    }
}
