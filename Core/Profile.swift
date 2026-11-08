import Foundation

// Turning the user's own publications into things they can follow, as suggestions they
// choose from, not as something the app does behind their back. Pure and tested; the
// fetching is in ProfileFetcher.swift.

enum Orcid {
    /// "0000-0003-1056-5980" from what a person might type or paste: with or without
    /// the hyphens, or as a link. nil unless it is sixteen characters ending in a valid
    /// check character (ISO 7064 mod 11-2), which catches nearly every typing slip.
    static func normalised(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for prefix in ["HTTPS://ORCID.ORG/", "HTTP://ORCID.ORG/", "ORCID.ORG/"] where t.hasPrefix(prefix) {
            t.removeFirst(prefix.count)
        }
        t = t.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard t.count == 16 else { return nil }
        let digits = Array(t)
        guard digits.prefix(15).allSatisfy({ $0.isNumber && $0.isASCII }),
              digits[15].isASCII, digits[15].isNumber || digits[15] == "X" else { return nil }
        var total = 0
        for d in digits.prefix(15) { total = (total + (d.wholeNumberValue ?? 0)) * 2 }
        let result = (12 - total % 11) % 11
        guard digits[15] == (result == 10 ? "X" : Character(String(result))) else { return nil }
        let s = String(digits)
        return "\(s.prefix(4))-\(s.dropFirst(4).prefix(4))-\(s.dropFirst(8).prefix(4))-\(s.suffix(4))"
    }
}

/// Someone whose publications the feed learns from besides the user: a supervisor, a
/// group leader, anyone whose work defines the field to follow. Most useful to a PhD
/// student who has no papers yet.
struct ProfileSource: Codable, Hashable {
    var orcid: String
    /// What the user calls them: "Supervisor". Empty falls back to their name.
    var label: String = ""

    init(orcid: String, label: String = "") {
        self.orcid = orcid
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case orcid, label }

    /// Tolerant like every stored type: a missing label is just empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orcid = try c.decode(String.self, forKey: .orcid)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
    }
}

/// What a paper says about the person it belongs to, reduced to what can be followed.
struct ProfileWork: Equatable {
    var year: Int
    var topics: [Entity] = []
    /// The phrases OpenAlex finds in the paper, strongest first. The id is the phrase in lower case.
    var keywords: [Entity] = []
    /// nil for a repository (a university library is not a journal to follow).
    var journal: Entity?
    /// Everyone on the paper except the profile's own person.
    var people: [Entity] = []
    /// Where the profile's own person worked on this paper.
    var institutions: [Entity] = []
    var funders: [Entity] = []
}

/// One person's works, and who they are in them.
struct ProfileSourceWorks {
    var label: String
    var works: [ProfileWork]
}

enum SuggestionKind: String, CaseIterable {
    case topic, keyword, journal, researcher, institution, funder

    var title: String {
        switch self {
        case .topic: return "Topics"
        case .keyword: return "Keywords"
        case .journal: return "Journals"
        case .researcher: return "Researchers (co-authors)"
        case .institution: return "Institutions"
        case .funder: return "Funders"
        }
    }

    /// How many are ticked to begin with, and how often one must occur to be ticked.
    var defaultCount: Int {
        switch self {
        case .topic: return 8
        case .keyword: return 6
        case .journal: return 6
        case .researcher: return 5
        // Following an institution or a funder lists a very large and mixed set of papers
        // (a university publishes in every field), so neither is ticked unless the user does it.
        case .institution: return 0
        case .funder: return 0
        }
    }

    /// A co-author is only worth following if you have worked together more than once or twice:
    /// everything a prolific one publishes would otherwise fill the feed.
    var minimumPapers: Int {
        switch self {
        case .institution: return 1
        case .researcher, .keyword: return 3
        default: return 2
        }
    }
}

struct ProfileSuggestion: Identifiable, Equatable {
    var kind: SuggestionKind
    var entity: Entity
    /// How many papers it appears in.
    var count: Int
    var latestYear: Int
    /// Recent papers count for more, so what the user still works on comes first.
    var score: Double
    /// Whose papers it came from: "you", "Supervisor".
    var fromNames: [String]
    /// Ticked by default: recent and frequent enough. The rest are listed, unticked.
    var selected: Bool
    /// A reason to think twice, shown with it: a journal that publishes a great deal.
    var note: String? = nil

    var id: String { kind.rawValue + "/" + entity.id }
}

enum ProfileAnalysis {
    /// Papers older than this many years no longer count as "still following" by default.
    static let recentYears = 4
    /// A paper's weight halves about every two years.
    static let timeConstant = 3.0
    static let listed = 25

    /// A journal with more than this many papers in all is a general one: following it would
    /// list a flood from every field. It is offered, unticked, with a note saying so.
    static let largeJournal = 100_000

    /// A keyword that matches more papers than this in a month is too broad to follow as it
    /// stands: a follow can list only the newest few hundred, and most would be beside the point.
    static let broadKeyword = 150

    /// `journalSizes` is how many papers each journal has published, by id, where known.
    /// `keywordVolumes` is how many papers a month match each phrase (by lower-case phrase), where known.
    static func suggestions(_ sources: [ProfileSourceWorks], currentYear: Int,
                            journalSizes: [String: Int] = [:],
                            keywordVolumes: [String: Int] = [:]) -> [SuggestionKind: [ProfileSuggestion]] {
        var out: [SuggestionKind: [ProfileSuggestion]] = [:]
        for kind in SuggestionKind.allCases {
            var byID: [String: ProfileSuggestion] = [:]
            for source in sources {
                for work in source.works {
                    let weight = exp(-Double(max(currentYear - work.year, 0)) / timeConstant)
                    // One paper counts once for an entity, however many times it names it.
                    var seen: Set<String> = []
                    for entity in entities(of: kind, in: work) where seen.insert(entity.id).inserted {
                        var s = byID[entity.id] ?? ProfileSuggestion(kind: kind, entity: entity, count: 0, latestYear: 0,
                                                                     score: 0, fromNames: [], selected: false)
                        s.count += 1
                        s.score += weight
                        s.latestYear = max(s.latestYear, work.year)
                        if !s.fromNames.contains(source.label) { s.fromNames.append(source.label) }
                        byID[entity.id] = s
                    }
                }
            }
            var ordered = byID.values.sorted {
                $0.score != $1.score ? $0.score > $1.score : $0.entity.name < $1.entity.name
            }
            ordered = Array(ordered.prefix(listed))
            var ticked = 0
            for i in ordered.indices {
                let s = ordered[i]
                if kind == .journal, let size = journalSizes[s.entity.id], size >= largeJournal {
                    ordered[i].note = "A large general journal (about \(size / 1000) thousand papers): following it lists a great many."
                    continue
                }
                if kind == .keyword, let volume = keywordVolumes[s.entity.id], volume >= broadKeyword {
                    ordered[i].note = "Broad: about \(volume) papers a month match it. Leave it out, or add conditions to it afterwards."
                    continue
                }
                if ticked < kind.defaultCount, s.count >= kind.minimumPapers, s.latestYear >= currentYear - recentYears {
                    ordered[i].selected = true
                    ticked += 1
                }
            }
            out[kind] = ordered
        }
        return out
    }

    private static func entities(of kind: SuggestionKind, in work: ProfileWork) -> [Entity] {
        switch kind {
        case .topic: return work.topics
        case .keyword: return work.keywords
        case .journal: return work.journal.map { [$0] } ?? []
        case .researcher: return work.people
        case .institution: return work.institutions
        case .funder: return work.funders
        }
    }

    /// What of the user's own people to leave out of the co-authors: an OpenAlex id
    /// matches exactly; names, which come as "Mouraux A" or "André Mouraux", match on the
    /// surname and first initial.
    static func isSameAuthor(_ a: Entity, _ b: Entity) -> Bool {
        if a.id == b.id { return true }
        // Two OpenAlex ids that differ are two people; only a name can be the same person under another spelling.
        func parts(_ name: String) -> (surname: String, initial: Character)? {
            let p = Paper(id: "x", title: "t", date: "d", authors: [name])
            guard let surname = Merge.firstSurname(p) else { return nil }
            let words = name.split(separator: " ").map(String.init)
            guard let first = words.first, let last = words.last else { return nil }
            let given = (words.count > 1 && last.count <= 2 && last == last.uppercased()) ? last : first
            return given.first.map { (surname, Character($0.lowercased())) }
        }
        guard SourceRouting.isNamed(a.id) || SourceRouting.isNamed(b.id),
              let x = parts(a.name), let y = parts(b.name) else { return false }
        return x.surname == y.surname && x.initial == y.initial
    }
}
