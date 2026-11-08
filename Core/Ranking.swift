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

    init(_ base: TextEmbedder, stored: Data? = nil) {
        self.base = base
        if let stored, let saved = try? PropertyListDecoder().decode([String: Data].self, from: stored) {
            for (key, bytes) in saved {
                guard let k = UInt64(key, radix: 16) else { continue }
                store[k] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
    }

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
        guard !candidates.isEmpty else { return [] }
        let similarity = similarities(candidates, profileTexts: profileTexts, embedder: embedder)

        var ranked: [RankedPaper] = []
        for (i, paper) in candidates.enumerated() {
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
            score += impactBoost(paper.journalImpact, weight: settings.impactWeight)
            score += authorBoost(paper, weight: settings.authorWeight, focus: settings.authorFocus)
            ranked.append(RankedPaper(paper: paper, score: score, similarity: similarity[i]))
        }
        return ranked.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.paper.date > $1.paper.date
        }
    }

    // MARK: Similarity

    static func similarities(_ candidates: [Paper], profileTexts: [String],
                             embedder: TextEmbedder?) -> [Double] {
        let lexical = percentiles(lexicalScores(candidates, profileTexts: profileTexts))
        guard let embedder, let semantic = semanticScores(candidates, profileTexts: profileTexts, embedder: embedder)
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

    private static func lexicalScores(_ candidates: [Paper], profileTexts: [String]) -> [Double] {
        let profile = profileTexts.map(Words.tokens)
        let cands = candidates.map { Words.tokens(text($0)) }
        let model = TfIdf(documents: profile + cands)
        let profileVectors = profile.map(model.vector)
        return cands.map { tokens in
            let v = model.vector(tokens)
            return topMean(profileVectors.map { TfIdf.cosine(v, $0) })
        }
    }

    /// nil when the embedder cannot read the profile at all (no model on this device).
    private static func semanticScores(_ candidates: [Paper], profileTexts: [String],
                                       embedder: TextEmbedder) -> [Double?]? {
        let profile = profileTexts.compactMap { embedder.vector(for: $0) }.map(Vectors.normalise)
        guard !profile.isEmpty else { return nil }
        return candidates.map { p in
            guard let v = embedder.vector(for: text(p)).map(Vectors.normalise) else { return nil }
            return topMean(profile.map { Vectors.dot(v, $0) })
        }
    }

    /// Replace each value by its rank among the others, 0…1, ties sharing their
    /// average. Raw cosines from different models live on different scales
    /// (sentence embeddings sit between 0.5 and 0.9 whatever the topic), so the
    /// only comparison that means anything is "closer than most of the others".
    static func percentiles(_ values: [Double]) -> [Double] {
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
