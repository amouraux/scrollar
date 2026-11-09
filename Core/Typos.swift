import Foundation

// Misspelled searches. The sources are not forgiving (Europe PMC finds nothing for "nociceptve"), and a scientific
// word is not in a dictionary, so a dictionary alone would "correct" good words. A word is corrected only toward a
// word the app has actually seen: what the user follows, keeps and has searched, and what the sources just returned.
// A dictionary's guesses are tried only when a search found nothing at all. Pure and tested.

enum Typos {
    /// The words of a text: lowercased runs of letters, two or more of them.
    static func words(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for ch in text.lowercased() {
            if ch.isLetter { current.append(ch) } else { if current.count >= 2 { out.append(current) }; current = "" }
        }
        if current.count >= 2 { out.append(current) }
        return out
    }

    /// How often each word occurs in the texts.
    static func vocabulary(_ texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for t in texts { for w in words(t) { counts[w, default: 0] += 1 } }
        return counts
    }

    static func merge(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
        a.merging(b, uniquingKeysWith: +)
    }

    /// How many slips a word of this length may have: none for a short one, which could be anything.
    static func allowedSlips(_ length: Int) -> Int { length >= 8 ? 2 : length >= 4 ? 1 : 0 }

    /// Edit distance where swapping two neighbours counts as one slip, or nil when it exceeds `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return nil }
        var prev2: [Int] = [], prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { row[j] = min(row[j], prev2[j - 2] + 1) }
            }
            prev2 = prev; prev = row
        }
        let d = a.isEmpty ? b.count : prev[b.count]
        return d <= limit ? d : nil
    }

    /// The ways a phrase could be put right, best first, at most `limit`: the first puts every misspelled word right
    /// by its best candidate, the second by its second best, and so on. A word is put right only toward a word in
    /// `vocabulary` that is within a slip or two of it and clearly commoner (at least three occurrences, and five
    /// times as many as the word itself), best the closest then the commonest. `guesses` is a dictionary's offer for
    /// a word the vocabulary has never seen, added after the vocabulary's own candidates, and used only where the
    /// caller passes it. Empty when nothing looks misspelled.
    static func alternatives(_ phrase: String, vocabulary: [String: Int], guesses: ((String) -> [String])? = nil,
                             limit: Int = 3) -> [String] {
        struct Part { var whole: String; var lead: String; var trail: String; var raw: String; var options: [String] }
        var parts: [Part] = []
        for token in phrase.split(whereSeparator: \.isWhitespace) {
            // Quotes and brackets around a word stay where they are.
            let whole = String(token)
            let lead = String(whole.prefix { !$0.isLetter }), trail = String(whole.reversed().prefix { !$0.isLetter }.reversed())
            let raw = String(whole.dropFirst(lead.count).dropLast(trail.count))
            let word = raw.lowercased()
            let slips = allowedSlips(word.count)
            var options: [String] = []
            if slips > 0, raw.allSatisfy(\.isLetter) {
                let own = vocabulary[word] ?? 0
                var near: [(word: String, distance: Int, count: Int)] = []
                for (candidate, count) in vocabulary where candidate != word && count >= 3 && count >= 5 * own {
                    if let d = distance(word, candidate, limit: slips) { near.append((candidate, d, count)) }
                }
                near.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.count > $1.count }
                options = near.map(\.word)
                if own == 0, let guesses {
                    for g in guesses(word).map({ $0.lowercased() }) where g != word && !g.contains(" ") && !options.contains(g) {
                        if distance(word, g, limit: slips) != nil { options.append(g) }
                    }
                }
            }
            parts.append(Part(whole: whole, lead: lead, trail: trail, raw: raw, options: Array(options.prefix(limit))))
        }
        guard parts.contains(where: { !$0.options.isEmpty }) else { return [] }
        var out: [String] = []
        for rank in 0..<limit {
            guard parts.contains(where: { rank < $0.options.count }) else { break }
            let phraseRanked = parts.map { p -> String in
                guard !p.options.isEmpty else { return p.whole }
                return p.lead + matchCase(p.options[min(rank, p.options.count - 1)], like: p.raw) + p.trail
            }.joined(separator: " ")
            if !out.contains(phraseRanked) { out.append(phraseRanked) }
        }
        return out
    }

    /// The best way to put the phrase right, or nil when nothing looks misspelled.
    static func suggest(_ phrase: String, vocabulary: [String: Int], guesses: ((String) -> [String])? = nil) -> String? {
        alternatives(phrase, vocabulary: vocabulary, guesses: guesses, limit: 1).first
    }

    /// The corrected word written the way the original was (a capital at the start stays).
    private static func matchCase(_ word: String, like original: String) -> String {
        let letters = original.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return word.uppercased() }
        if let first = letters.first, first.isUppercase { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }
}
