import Foundation

enum Words {
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "has", "have",
        "had", "not", "but", "can", "its", "into", "than", "their", "these", "those", "which",
        "between", "using", "used", "use", "study", "studies", "results", "result", "methods",
        "method", "conclusion", "conclusions", "background", "also", "may", "been", "both",
        "more", "other", "such", "our", "who", "how", "what", "when", "after", "during",
    ]

    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }
}

/// A bag-of-words model: no network, no model download, and the profile never
/// leaves the device. It catches shared jargon; the embedder catches shared meaning.
struct TfIdf {
    private let idf: [String: Double]
    private let unseenIDF: Double

    init(documents: [[String]]) {
        var df: [String: Int] = [:]
        for d in documents {
            for t in Set(d) { df[t, default: 0] += 1 }
        }
        let n = Double(max(documents.count, 1))
        var table: [String: Double] = [:]
        for (term, count) in df { table[term] = log((n + 1) / (Double(count) + 1)) + 1 }
        idf = table
        unseenIDF = log(n + 1) + 1
    }

    func vector(_ tokens: [String]) -> [String: Double] {
        var tf: [String: Double] = [:]
        for t in tokens { tf[t, default: 0] += 1 }
        var v: [String: Double] = [:]
        for (term, count) in tf { v[term] = (1 + log(count)) * (idf[term] ?? unseenIDF) }
        return TfIdf.normalise(v)
    }

    static func normalise(_ v: [String: Double]) -> [String: Double] {
        let norm = v.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.mapValues { $0 / norm }
    }

    /// Both vectors are already unit length, so the dot product is the cosine.
    static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        var dot = 0.0
        for (term, w) in small { dot += w * (large[term] ?? 0) }
        return dot
    }
}

/// Turns a text into a vector of meaning. Behind a protocol so this file stays
/// Foundation-only: the Apple implementation (NaturalLanguage) is in Embedding.swift
/// and the tests use a stand-in.
protocol TextEmbedder {
    func vector(for text: String) -> [Double]?
    /// Which model made the vectors. Vectors from two models are not comparable, so a stored cache
    /// is used only by the model that wrote it.
    var modelID: String { get }
}

extension TextEmbedder {
    var modelID: String { "unknown" }
}

/// Embedding a paper costs about 60 ms per sentence, so a refresh that re-reads
/// last week's papers is mostly wasted work. Vectors are kept by a hash of the
/// text and survive on disk between launches (`snapshot()` / `init(stored:)`).
final class CachingEmbedder: TextEmbedder {
    private let base: TextEmbedder
    private let lock = NSLock()
    private var store: [UInt64: [Float]] = [:]
    private(set) var hits = 0
    private(set) var misses = 0

    /// The key under which a snapshot records its model. A snapshot written before there was one came
    /// from Apple's sentence model, the only one then.
    static let modelKey = "_model"
    static let legacyModelID = "apple-sentence"

    init(_ base: TextEmbedder, stored: Data? = nil) {
        self.base = base
        if let stored, let saved = try? PropertyListDecoder().decode([String: Data].self, from: stored),
           saved[CachingEmbedder.modelKey].map({ String(decoding: $0, as: UTF8.self) }) ?? CachingEmbedder.legacyModelID == base.modelID {
            for (key, bytes) in saved {
                guard let k = UInt64(key, radix: 16) else { continue }
                store[k] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
    }

    var modelID: String { base.modelID }

    func vector(for text: String) -> [Double]? {
        let key = CachingEmbedder.hash(text)
        lock.lock()
        if let v = store[key] { hits += 1; lock.unlock(); return v.map(Double.init) }
        lock.unlock()

        guard let v = base.vector(for: text) else { return nil }
        lock.lock()
        misses += 1
        store[key] = v.map(Float.init)
        lock.unlock()
        return v
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return store.count }

    /// Keep only vectors for these texts, so the file does not grow with every
    /// paper ever seen. Call it after a refresh with the texts that were just used.
    func snapshot(keeping texts: [String]? = nil) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let wanted = texts.map { Set($0.map(CachingEmbedder.hash)) }
        var out: [String: Data] = [:]
        for (key, v) in store where wanted?.contains(key) ?? true {
            out[String(key, radix: 16)] = v.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        out[CachingEmbedder.modelKey] = Data(base.modelID.utf8)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(out)
    }

    /// FNV-1a: unlike `hashValue`, the same text hashes the same on every launch.
    static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return h
    }
}

enum Vectors {
    static func normalise(_ v: [Double]) -> [Double] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
}

struct RankedPaper: Codable {
    let paper: Paper
    let score: Double
    /// How close the paper is to the user's own work, 0 to 1: its rank among
    /// the candidates, not an absolute cosine (see `Ranker.percentiles`).
    let similarity: Double
}

enum Ranker {
    // First-guess weights. Similarity is a percentile, so it spans 0…1 and
    // everything else is sized against that. The two sliders in FeedSettings
    // scale the first and the fourth: at their default of 0.5 they give the
    // values these constants were tuned with (2.0 and 0.5).
    static let similarityScale = 4.0       // × settings.closeness
    static let recencyScale = 1.0          // × settings.recency
    static let extraSeedBonus = 0.5
    static let citesYouBonus = 1.5
    /// Something the user chose to follow should surface even when it is not
    /// close to their own work: a journal followed for its breadth, say.
    static let followedBonus = 0.8
    /// × settings.impactWeight. The range is about -1 to +2 at full weight, so a
    /// strong preference moves a paper a few places, not to the top on journal alone.
    static let impactScale = 3.0
    /// × settings.authorWeight; same size as the journal's, for the same reason.
    static let authorScale = 3.0
    static let recencyHalfLifeDays = 14.0
    static let repositoryPenalty = 0.4
    /// A researcher has several themes. Averaging all their papers blurs them
    /// into one; comparing with the few nearest papers does not.
    static let neighbours = 3
    static let embeddingShare = 0.6

    /// 0 at no figure and at a journal cited about twice per paper; negative below,
    /// up to about 0.65 for a journal cited twenty times or more. Logarithmic, because
    /// the difference between 1 and 3 matters more than between 21 and 23. A paper
    /// with no figure (a preprint, a new journal) is neutral, not penalised.
    static func impactBoost(_ impact: Double?, weight: Double) -> Double {
        guard weight > 0, let impact, impact >= 0 else { return 0 }
        let level = min(log(1 + impact) / log(21.0), 1)
        return impactScale * weight * (level - 0.35)
    }

    /// The h-index that counts for this paper, if there is one. For "either", the
    /// higher of the two that are known.
    static func chosenH(_ paper: Paper, focus: BylineChoice) -> Int? {
        switch focus {
        case .first: return paper.firstAuthorH
        case .last: return paper.lastAuthorH
        case .both: return [paper.firstAuthorH, paper.lastAuthorH].compactMap { $0 }.max()
        }
    }

    /// Zero at an h-index of about ten, negative below it, up to about +0.5 at a
    /// hundred. Logarithmic, since 5 against 15 is a bigger step than 85 against
    /// 95; an unknown author is neutral. It favours the established over the
    /// early-career, and h-indexes differ by field: the slider is the user's call.
    static func authorBoost(_ paper: Paper, weight: Double, focus: BylineChoice) -> Double {
        guard weight > 0, let h = chosenH(paper, focus: focus), h >= 0 else { return 0 }
        let level = min(log(1 + Double(h)) / log(101.0), 1)
        return authorScale * weight * (level - 0.5)
    }

    static func rank(_ candidates: [Paper], profileTexts: [String], embedder: TextEmbedder? = nil,
                     settings: FeedSettings = FeedSettings(), today: Date) -> [RankedPaper] {
        rank(candidates, profile: profileTexts.map { ProfileEntry(text: $0) }, embedder: embedder,
             settings: settings, today: today)
    }

    /// `profile` is what the feed moves toward, each text with how much it counts; `avoid` is what it
    /// moves away from (the papers the user hid). A paper is lowered only if it is among the few closest
    /// to what was hidden, and closer to that than to anything the user wants; one the user follows, or
    /// that cites their work, is never lowered.
    static func rank(_ candidates: [Paper], profile: [ProfileEntry], avoid: [ProfileEntry] = [],
                     embedder: TextEmbedder? = nil, settings: FeedSettings = FeedSettings(),
                     today: Date) -> [RankedPaper] {
        guard !candidates.isEmpty else { return [] }
        let similarity = similarities(candidates, profile: profile, embedder: embedder)
        let lowering = avoid.isEmpty || settings.hideStrength <= 0 ? []
            : avoidance(candidates, profile: profile, avoid: avoid, embedder: embedder)

        var ranked: [RankedPaper] = []
        for (i, original) in candidates.enumerated() {
            var paper = original
            paper.loweredBy = nil
            var score = similarityScale * settings.closeness * similarity[i]
            score += extraSeedBonus * Double(max(paper.reasons.count - 1, 0))
            if paper.citesYou { score += citesYouBonus }
            if paper.followed { score += followedBonus }
            if let age = ageInDays(paper.date, today: today) {
                score += recencyScale * settings.recency * exp(-max(age, 0) / recencyHalfLifeDays)
            }
            // Preprint servers are repositories too, and are where the newest work in
            // a field appears first; the penalty is for Zenodo and library records.
            if paper.isRepository && paper.kind != .preprint { score -= repositoryPenalty }
            score += settings.weight(for: paper.kind).adjustment
            if let importance = settings.keywordImportance(of: paper) { score += importance.bonus }
            score += impactBoost(paper.journalImpact, weight: settings.impactWeight)
            score += authorBoost(paper, weight: settings.authorWeight, focus: settings.byline)
            score += levelBonus(paper, settings)
            if i < lowering.count, lowering[i].factor > 0, !paper.followed, !paper.citesYou {
                score -= avoidScale * settings.hideStrength * lowering[i].factor
                paper.loweredBy = lowering[i].nearest.flatMap { avoid[$0].title } ?? "a paper you hid"
            }
            ranked.append(RankedPaper(paper: paper, score: score, similarity: similarity[i]))
        }
        return ranked.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.paper.date > $1.paper.date
        }
    }

    // MARK: Similarity

    static func similarities(_ candidates: [Paper], profileTexts: [String],
                             embedder: TextEmbedder?) -> [Double] {
        similarities(candidates, profile: profileTexts.map { ProfileEntry(text: $0) }, embedder: embedder)
    }

    static func similarities(_ candidates: [Paper], profile: [ProfileEntry], embedder: TextEmbedder?) -> [Double] {
        let lexical = percentiles(lexicalScores(candidates, profile: profile))
        guard let embedder, let semantic = semanticScores(candidates, profile: profile, embedder: embedder)
        else { return lexical }

        // A paper the embedder could not read falls back to its lexical score.
        let semanticPct = percentiles(semantic.map { $0 ?? 0 })
        return candidates.indices.map { i in
            semantic[i] == nil ? lexical[i] : embeddingShare * semanticPct[i] + (1 - embeddingShare) * lexical[i]
        }
    }

    /// The text that stands for a paper: what is embedded, so also what a cache is keyed on.
    static func text(_ p: Paper) -> String {
        p.title + (p.abstract.map { ". " + $0 } ?? "")
    }

    private static func topMean(_ scores: [Double]) -> Double {
        let top = scores.sorted(by: >).prefix(neighbours)
        return top.isEmpty ? 0 : top.reduce(0, +) / Double(top.count)
    }

    private static func lexicalScores(_ candidates: [Paper], profile entries: [ProfileEntry]) -> [Double] {
        let profile = entries.map { Words.tokens($0.text) }
        let cands = candidates.map { Words.tokens(text($0)) }
        let model = TfIdf(documents: profile + cands)
        let profileVectors = profile.map(model.vector)
        return cands.map { tokens in
            let v = model.vector(tokens)
            return topMean(profileVectors.enumerated().map { TfIdf.cosine(v, $0.element) * entries[$0.offset].weight })
        }
    }

    /// nil when the embedder cannot read the profile at all (no model on this device).
    private static func semanticScores(_ candidates: [Paper], profile entries: [ProfileEntry],
                                       embedder: TextEmbedder) -> [Double?]? {
        let profile: [(vector: [Double], weight: Double)] = entries.compactMap { e in
            embedder.vector(for: e.text).map { (Vectors.normalise($0), e.weight) }
        }
        guard !profile.isEmpty else { return nil }
        return candidates.map { p in
            guard let v = embedder.vector(for: text(p)).map(Vectors.normalise) else { return nil }
            return topMean(profile.map { Vectors.dot(v, $0.vector) * $0.weight })
        }
    }

    /// What the levels the user set add to a paper that carries the thing: up for Higher and Maximum, down for Lower,
    /// kept within bounds so that no pile of them decides the feed alone. Nothing at all with no level set.
    static func levelBonus(_ paper: Paper, _ settings: FeedSettings) -> Double {
        let active = settings.levels.filter { $0.level != .hide && $0.level != .normal }
        guard !active.isEmpty else { return 0 }
        let text = active.contains { $0.kind == .keyword } ? (paper.title + " " + (paper.abstract ?? "")).lowercased() : nil
        let total = active.filter { $0.matches(paper, text: text) }.reduce(0.0) { $0 + $1.level.bonus }
        return min(max(total, -1.5), 2.0)
    }

    // MARK: Moving away from what was hidden

    /// How hard a paper at the very closest to what was hidden is lowered, at full strength. The whole
    /// range of closeness to the user's work is 4; the default strength is half.
    static let avoidScale = 2.0
    /// Only this share of the feed, the papers closest to what was hidden, can be lowered.
    static let avoidShare = 0.1
    /// Fewer papers than this say too little about what is close to what.
    static let avoidFewest = 20

    struct Avoidance {
        /// 0 for no lowering, up to 1 for the paper closest to what was hidden.
        var factor: Double
        /// Which of the avoided entries it is closest to.
        var nearest: Int?
    }

    struct RawScore {
        /// The mean of the three nearest, each weighted, blended from the meaning model and the words.
        var value: Double
        /// The entry that came nearest.
        var nearest: Int?
    }

    private static func argmax(_ values: [Double]) -> Int? {
        guard let best = values.max(), best > 0 else { return nil }
        return values.firstIndex(of: best)
    }

    /// For each group of entries, how close each candidate is to it on one scale for all groups, so
    /// that two groups can be compared with each other. (The percentile similarity cannot: it only says
    /// how a candidate ranks among the others.)
    static func rawScores(_ candidates: [Paper], groups: [[ProfileEntry]], embedder: TextEmbedder?) -> [[RawScore]] {
        let groupTokens = groups.map { $0.map { Words.tokens($0.text) } }
        let candidateTokens = candidates.map { Words.tokens(text($0)) }
        let model = TfIdf(documents: groupTokens.flatMap { $0 } + candidateTokens)
        let groupVectors = groupTokens.map { $0.map(model.vector) }
        let candidateVectors = candidateTokens.map(model.vector)

        var groupMeaning: [[[Double]?]]?
        var candidateMeaning: [[Double]?] = []
        if let embedder {
            let vectors = groups.map { $0.map { embedder.vector(for: $0.text).map(Vectors.normalise) } }
            if vectors.contains(where: { $0.contains { $0 != nil } }) {
                groupMeaning = vectors
                candidateMeaning = candidates.map { embedder.vector(for: text($0)).map(Vectors.normalise) }
            }
        }
        return groups.indices.map { g in
            candidates.indices.map { i in
                let words = groupVectors[g].enumerated().map { TfIdf.cosine(candidateVectors[i], $0.element) * groups[g][$0.offset].weight }
                let wordValue = topMean(words)
                guard let groupMeaning, let cv = candidateMeaning[i] else { return RawScore(value: wordValue, nearest: argmax(words)) }
                var meaning: [Double] = []
                var index: [Int] = []
                for (j, v) in groupMeaning[g].enumerated() {
                    guard let v else { continue }
                    meaning.append(Vectors.dot(cv, v) * groups[g][j].weight)
                    index.append(j)
                }
                guard !meaning.isEmpty else { return RawScore(value: (1 - embeddingShare) * wordValue, nearest: argmax(words)) }
                return RawScore(value: embeddingShare * topMean(meaning) + (1 - embeddingShare) * wordValue,
                                nearest: argmax(meaning).map { index[$0] })
            }
        }
    }

    /// Who is to be lowered, and by how much of the full amount. A paper counts only if it is closer to
    /// what was hidden than to anything the user wants, and among the closest tenth of the feed to what
    /// was hidden: so a hide cannot flatten a field, and a field the user has since come to want is
    /// not lowered, however much of it was hidden once.
    static func avoidance(_ candidates: [Paper], profile: [ProfileEntry], avoid: [ProfileEntry],
                          embedder: TextEmbedder?) -> [Avoidance] {
        let none = Avoidance(factor: 0, nearest: nil)
        guard candidates.count >= avoidFewest, !avoid.isEmpty else { return candidates.map { _ in none } }
        let raw = rawScores(candidates, groups: [profile, avoid], embedder: embedder)
        let margin = candidates.indices.map { raw[1][$0].value - raw[0][$0].value }
        let percentile = percentiles(margin)
        return candidates.indices.map { i in
            guard margin[i] > 0, percentile[i] > 1 - avoidShare else { return none }
            // The percentile says how far into the closest tenth it is; the weight of the hide it is
            // closest to says how much that hide still counts, so an older hide lowers less.
            let nearest = raw[1][i].nearest
            let counts = nearest.map { avoid[$0].weight } ?? 1
            return Avoidance(factor: (percentile[i] - (1 - avoidShare)) / avoidShare * counts, nearest: nearest)
        }
    }

    // MARK: Showing what the thumbs do

    struct Influence {
        struct Pull { var paper: Paper; var because: String; var strength: Double }
        struct Push { var paper: Paper; var because: String; var factor: Double }
        /// The papers most like what was put on the reading list or marked For me, with the one each is like.
        var pulled: [Pull]
        /// The papers lowered because of what was hidden, with the hidden paper each is like.
        var pushed: [Push]
    }

    static func influence(_ papers: [Paper], profile: [ProfileEntry], avoid: [ProfileEntry],
                          embedder: TextEmbedder?, limit: Int = 8) -> Influence {
        let liked = profile.filter { $0.title != nil }
        var pulled: [Influence.Pull] = []
        if !liked.isEmpty, !papers.isEmpty {
            let raw = rawScores(papers, groups: [liked], embedder: embedder)[0]
            pulled = papers.indices.compactMap { i in
                guard raw[i].value > 0, let n = raw[i].nearest, let title = liked[n].title else { return nil }
                return Influence.Pull(paper: papers[i], because: title, strength: raw[i].value)
            }.sorted { $0.strength > $1.strength }
            pulled = Array(pulled.prefix(limit))
        }
        let lowering = avoidance(papers, profile: profile, avoid: avoid, embedder: embedder)
        let pushed = papers.indices.compactMap { i -> Influence.Push? in
            guard lowering[i].factor > 0, !papers[i].followed, !papers[i].citesYou,
                  let n = lowering[i].nearest, let title = avoid[n].title else { return nil }
            return Influence.Push(paper: papers[i], because: title, factor: lowering[i].factor)
        }.sorted { $0.factor > $1.factor }
        return Influence(pulled: pulled, pushed: Array(pushed.prefix(limit)))
    }

    /// Replace each value by its rank among the others, 0…1, ties sharing their
    /// average. Raw cosines from different models live on different scales
    /// (sentence embeddings sit between 0.5 and 0.9 whatever the topic), so the
    /// only comparison that means anything is "closer than most of the others".
    static func percentiles(_ values: [Double]) -> [Double] {
        // Two scores that differ only by rounding noise (a sum taken in another order) are a tie:
        // without this the same feed could rank differently twice, and equal papers swap places.
        let values = values.map { ($0 * 1e9).rounded() / 1e9 }
        let n = values.count
        guard n > 1 else { return Array(repeating: 0.5, count: n) }
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = [Double](repeating: 0, count: n)
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && values[order[j + 1]] == values[order[i]] { j += 1 }
            let rank = Double(i + j) / 2 / Double(n - 1)
            for k in i...j { result[order[k]] = rank }
            i = j + 1
        }
        return result
    }

    // MARK: Dates

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func ageInDays(_ date: String, today: Date) -> Double? {
        guard let d = dayFormatter.date(from: date) else { return nil }
        return today.timeIntervalSince(d) / 86_400
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
