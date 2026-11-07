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

struct KeywordRule: Codable, Hashable {
    var phrase: String
    /// Every one of these must appear in the title or abstract.
    var alsoRequire: [String] = []
    /// None of these may appear. "attention" without "deficit" is a different literature.
    var exclude: [String] = []

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

    init(_ p: Paper) {
        id = p.dedupeKey
        title = p.title
        abstract = p.abstract
        date = p.date
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
    /// Hidden papers (dedupeKeys) never come back.
    var hidden: [String] = []

    mutating func save(_ p: Paper) {
        guard !saved.contains(where: { $0.id == p.dedupeKey }) else { return }
        saved.append(SavedPaper(p))
    }

    mutating func unsave(_ p: Paper) { saved.removeAll { $0.id == p.dedupeKey } }

    mutating func hide(_ p: Paper) {
        if !hidden.contains(p.dedupeKey) { hidden.append(p.dedupeKey) }
    }

    mutating func unhide(_ p: Paper) { hidden.removeAll { $0 == p.dedupeKey } }
}

struct FeedSettings: Codable, Equatable {
    /// Raise for any change an older copy of the app would misread.
    static let currentFormat = 1
    var formatVersion = FeedSettings.currentFormat

    // MARK: You
    var orcid: String? = nil
    /// Build the profile, the topic follows and the "cited you" section from
    /// the user's own papers. Off for someone with no publications yet.
    var useMyPublications = true

    // MARK: Follow
    var followedTopics: [Entity] = []
    var followedJournals: [Entity] = []
    var followedAuthors: [Entity] = []
    var followedInstitutions: [Entity] = []
    var followedFunders: [Entity] = []
    var followedKeywords: [KeywordRule] = []
    /// Papers whose new citations the user wants to hear about.
    var trackedPapers: [Entity] = []

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

    /// Everything except what the user did with the feed. Changing a follow or a
    /// filter means fetching again; hiding one paper does not.
    var withoutFeedback: FeedSettings {
        var s = self
        s.feedback = Feedback()
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

extension KeywordRule {
    enum CodingKeys: String, CodingKey { case phrase, alsoRequire, exclude }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decode(String.self, forKey: .phrase)
        alsoRequire = (try? c.decodeIfPresent([String].self, forKey: .alsoRequire)) ?? []
        exclude = (try? c.decodeIfPresent([String].self, forKey: .exclude)) ?? []
    }
}

extension Weight {
    /// A typo ("lowr") means normal, not a broken file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Weight(rawValue: raw) ?? .normal
    }
}

extension Feedback {
    enum CodingKeys: String, CodingKey { case saved, hidden }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saved = (try? c.decodeIfPresent([SavedPaper].self, forKey: .saved)) ?? []
        hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? []
    }
}

extension FeedSettings {
    enum CodingKeys: String, CodingKey {
        case formatVersion, orcid, useMyPublications
        case followedTopics, followedJournals, followedAuthors, followedInstitutions
        case followedFunders, followedKeywords, trackedPapers
        case mutedJournals, mutedAuthors, mutedTopics, mutedKeywords
        case kindWeights, daysBack, recency, closeness
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
        useMyPublications = get(.useMyPublications, useMyPublications)
        followedTopics = get(.followedTopics, followedTopics)
        followedJournals = get(.followedJournals, followedJournals)
        followedAuthors = get(.followedAuthors, followedAuthors)
        followedInstitutions = get(.followedInstitutions, followedInstitutions)
        followedFunders = get(.followedFunders, followedFunders)
        followedKeywords = get(.followedKeywords, followedKeywords)
        trackedPapers = get(.trackedPapers, trackedPapers)
        mutedJournals = get(.mutedJournals, mutedJournals)
        mutedAuthors = get(.mutedAuthors, mutedAuthors)
        mutedTopics = get(.mutedTopics, mutedTopics)
        mutedKeywords = get(.mutedKeywords, mutedKeywords)
        kindWeights = get(.kindWeights, kindWeights)
        daysBack = min(max(get(.daysBack, daysBack), 1), 365)
        recency = min(max(get(.recency, recency), 0), 1)
        closeness = min(max(get(.closeness, closeness), 0), 1)
        requireAbstract = get(.requireAbstract, requireAbstract)
        openAccessOnly = get(.openAccessOnly, openAccessOnly)
        seenExpiryDays = min(max(get(.seenExpiryDays, seenExpiryDays), 1), 60)
        showReadPapers = get(.showReadPapers, showReadPapers)
        languages = get(.languages, languages)
        feedback = get(.feedback, feedback)
    }
}
