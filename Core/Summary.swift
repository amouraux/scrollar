import Foundation

/// One sentence from an abstract, for a card that has room for one. This is a
/// choice among the abstract's own sentences, not a rewrite: it cannot invent
/// or distort a finding. Apple's on-device model could write a better line
/// (see the notes in the README); this is what works on every device.
enum Summary {
    static func sentence(from abstract: String?, maxLength: Int = 200) -> String? {
        guard let abstract, !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var sentences: [String] = []
        abstract.enumerateSubstrings(in: abstract.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(strippingHeading(s.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        sentences = sentences.filter { $0.count >= 25 }
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
