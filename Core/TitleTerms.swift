import Foundation

// The phrases of a paper's title that could be what it is about, for papers whose source gives no keywords (Crossref,
// arXiv and OSF records have none, nor does a feed cached before they were kept). A title is cut at the little words
// and the punctuation between its ideas: "Optimal parameters of rTMS for cognitive rehabilitation" gives "optimal
// parameters", "rTMS" and "cognitive rehabilitation". Pure and tested.

enum TitleTerms {
    private static let little: Set<String> = [
        "a", "an", "and", "or", "of", "in", "on", "for", "with", "the", "to", "by", "from", "at", "as", "is", "are", "was", "were",
        "vs", "versus", "using", "via", "after", "before", "between", "during", "among", "into", "than", "that", "this", "these",
        "those", "its", "their", "our", "your", "not", "no", "can", "does", "do", "how", "what", "why", "when", "which", "who",
        "toward", "towards", "through", "under", "over", "within", "without", "across", "per", "be", "been", "has", "have",
    ]

    /// Words that say what kind of paper it is, or that any title could carry, so that alone they say nothing.
    private static let generic: Set<String> = [
        "study", "studies", "analysis", "analyses", "review", "reviews", "systematic", "meta-analysis", "metaanalysis", "trial",
        "trials", "effect", "effects", "role", "evidence", "approach", "approaches", "insights", "insight", "comprehensive",
        "novel", "new", "outcomes", "outcome", "results", "report", "case", "update", "overview", "perspective", "perspectives",
        "randomized", "randomised", "controlled", "double-blind", "placebo-controlled", "clinical", "cohort", "naturalistic",
        "factors", "impact", "association", "associations", "potential", "recent", "current", "advances", "challenges",
        "future", "implications", "treatment", "patients", "adults", "letter", "editor", "commentary", "editorial",
    ]

    /// Up to `limit` phrases, the most specific first: longer ones, and acronyms (rTMS, EEG), before single plain words.
    static func phrases(from title: String, limit: Int = 3) -> [String] {
        // Cut at punctuation that separates ideas, then at the little words.
        var segments: [[String]] = []
        var current: [String] = []
        func flush() { if !current.isEmpty { segments.append(current); current = [] } }
        let separators = CharacterSet(charactersIn: ":;,.?!()[]\u{2013}\u{2014}/\"\u{201C}\u{201D}")
        for chunk in title.components(separatedBy: separators) {
            for raw in chunk.split(whereSeparator: \.isWhitespace) {
                let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}-"))
                if word.isEmpty { continue }
                if little.contains(word.lowercased()) { flush() } else { current.append(word) }
            }
            flush()
        }
        var scored: [(phrase: String, score: Double, position: Int)] = []
        var seen = Set<String>()
        for (position, words) in segments.enumerated() {
            var w = words
            // A generic word at either end adds nothing ("comprehensive meta-analysis" is not a topic).
            while let first = w.first, generic.contains(first.lowercased()) { w.removeFirst() }
            while let last = w.last, generic.contains(last.lowercased()) { w.removeLast() }
            guard !w.isEmpty, w.count <= 4 else { continue }
            let phrase = w.joined(separator: " ")
            guard phrase.count >= 4 || isAcronym(phrase), seen.insert(phrase.lowercased()).inserted else { continue }
            scored.append((phrase, Double(w.count) + (isAcronym(phrase) ? 1.5 : 0), position))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
            .prefix(limit).map(\.phrase)
    }

    /// rTMS, EEG, COVID-19: a capital after the first letter, or all capitals.
    private static func isAcronym(_ s: String) -> Bool {
        guard !s.contains(" "), s.count >= 2 else { return false }
        return s.dropFirst().contains(where: \.isUppercase)
    }
}
