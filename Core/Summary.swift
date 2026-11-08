import Foundation

/// One sentence from an abstract, for a card that has room for one. This is a
/// choice among the abstract's own sentences, not a rewrite: it cannot invent
/// or distort a finding. Apple's on-device model could write a better line
/// (see the notes in the README); this is what works on every device.
enum Summary {
    static func sentence(from abstract: String?, maxLength: Int = 200) -> String? {
        let sentences = cleanSentences(abstract)
        guard !sentences.isEmpty else { return nil }

        // Highest score wins; on a tie the later sentence does, because an
        // abstract ends with what was found and begins with why it matters.
        var best = sentences.count - 1
        var bestScore = Int.min
        for (i, s) in sentences.enumerated() {
            let score = self.score(s, position: i, of: sentences.count)
            if score >= bestScore { best = i; bestScore = score }
        }
        return clip(sentences[best], to: maxLength)
    }

    /// One or two whole sentences saying what the paper found, for a post that
    /// has room for them. Never cut off mid-sentence: a sentence that is too long
    /// loses to a shorter one, and only if every sentence is too long is one
    /// clipped. Two sentences only when both state a result and both fit.
    static func takeaway(from abstract: String?, maxLength: Int = 300) -> String? {
        let all = cleanSentences(abstract)
        guard !all.isEmpty else { return nil }
        let scored = all.enumerated().map { (index: $0.offset, text: $0.element,
                                              score: score($0.element, position: $0.offset, of: all.count)) }
        let fitting = scored.filter { $0.text.count <= 240 }
        let pool = fitting.isEmpty ? scored : fitting

        // Highest score; on a tie the later sentence, as in `sentence`.
        func better(_ a: (index: Int, text: String, score: Int), _ b: (index: Int, text: String, score: Int)) -> Bool {
            (a.score, a.index) < (b.score, b.index)
        }
        guard let best = pool.max(by: better) else { return nil }
        var chosen = [best]
        if let second = pool.filter({ $0.index != best.index && $0.score > 0 }).max(by: better),
           best.text.count + second.text.count + 1 <= maxLength {
            chosen.append(second)
        }
        let text = chosen.sorted { $0.index < $1.index }.map(\.text).joined(separator: " ")
        return clip(text, to: maxLength)
    }

    /// A language model asked for two sentences sometimes writes five, in
    /// paragraphs. Keep the first `n`, as one paragraph, and never cut mid-sentence
    /// unless the first sentence alone is too long.
    static func limited(_ text: String, sentences n: Int = 2, maxLength: Int = 320) -> String? {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var found: [String] = []
        flat.enumerateSubstrings(in: flat.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { found.append(s) }
            if found.count == n { stop = true }
        }
        guard var out = found.first else { return nil }
        for s in found.dropFirst() where out.count + s.count + 1 <= maxLength { out += " " + s }
        return clip(out, to: maxLength)
    }

    private static func cleanSentences(_ abstract: String?) -> [String] {
        guard let abstract, !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var sentences: [String] = []
        abstract.enumerateSubstrings(in: abstract.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(strippingHeading(s.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        return sentences.filter { $0.count >= 25 }
    }

    // MARK: Scoring

    private static let findingWords = [
        "we found", "we show", "we demonstrate", "we identified", "we observed", "we report",
        "results show", "results suggest", "revealed", "demonstrate", "indicate", "suggest",
        "conclude", "significantly", "associated with", "improved", "reduced", "increased",
        "decreased", "predict", "enhance", "mediate", "regulat",
    ]

    /// Sentences that say what the authors set out to do, not what happened.
    private static let intentWords = [
        "we aimed", "aim of", "aims to", "this study", "this review", "this article",
        "this paper", "here we", "we investigated", "we examined", "we assessed",
        "we evaluated", "we sought", "objective", "we explored", "the purpose",
    ]

    private static func score(_ sentence: String, position: Int, of count: Int) -> Int {
        let s = sentence.lowercased()
        var score = 0
        score += 3 * findingWords.filter { s.contains($0) }.prefix(2).count
        score -= 3 * (intentWords.contains { s.contains($0) } ? 1 : 0)
        if count > 1, position >= count / 2 { score += 1 }
        if sentence.count > 320 { score -= 2 }            // a paragraph is not a summary
        return score
    }

    // MARK: Cleaning

    // "Background And Aims: Chronic pain…" and "Results: …" at the start of a section.
    private static let labelled = try! NSRegularExpression(
        pattern: #"^(?:(?:abstract|background|introduction|objectives?|aims?|purpose|methods?|materials|results?|findings|conclusions?|discussion|significance|importance|design|setting|participants|rationale|context|and|&)[\s,]*)+:\s*"#,
        options: .caseInsensitive)

    // "Abstract Application of cold…" and "Introduction Persistent…": a heading
    // with no colon, glued to the first sentence by some publishers.
    private static let bare = try! NSRegularExpression(
        pattern: #"^(?:Abstract|Background|Introduction|Objectives?|Rationale)\s+(?=[A-Z])"#)

    static func strippingHeading(_ s: String) -> String {
        var out = s
        for regex in [labelled, bare] {
            let range = NSRange(out.startIndex..., in: out)
            if let m = regex.firstMatch(in: out, range: range), let r = Range(m.range, in: out) {
                out.removeSubrange(r)
                break
            }
        }
        // Having removed a heading, the sentence may now start in lower case.
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func clip(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let cut = s.prefix(limit)
        // End on a whole word.
        let words = cut.split(separator: " ", omittingEmptySubsequences: true).dropLast()
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:-– ")) + "…"
    }
}
