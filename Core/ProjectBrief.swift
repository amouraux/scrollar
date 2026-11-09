import Foundation

// Asking a language model what a project is about, to suggest what to follow. The words of the brief,
// the excerpt that goes with it and the reading of the answer are here, pure and tested, so that what
// leaves the device (when it leaves at all) is exactly what a test can read. The calls are in
// App/ProjectAI.swift: Apple's on-device model, or a Claude or ChatGPT account of the user's own.

enum ProjectBrief {
    /// How much of the project goes to a model. The on-device model has a small window (about four
    /// thousand tokens, brief and answer included); a service reads far more, but a few thousand
    /// words say what a project is about, and every word sent is a word paid for and shared.
    static let onDeviceLimit = 5_000
    static let remoteLimit = 14_000

    static let instructions = """
        You help a researcher set up a feed of new papers. You are given passages from the description \
        of their research project. List the search phrases that would find papers relevant to it: the \
        specific conditions, populations, methods, techniques and technical terms the project is about, \
        in the words a paper's title or abstract would use. Each phrase is two to four words, or an \
        acronym or a technical term that has no other common meaning. No general words (study, analysis, \
        patients), no names of people or institutions, no sentences. Give at most 12, the most important \
        first, one per line, with no numbering, no punctuation around them and no other text. Use only \
        what the passages are about.
        """

    static func prompt(_ excerpt: String) -> String {
        "Passages from the project description:\n\n" + excerpt
    }

    /// What is sent: the passages of the project (not headings, tables, links or reference lists),
    /// thinned evenly to fit `limit` characters, so the whole of the text is represented and none of
    /// it is cut off at the end.
    static func excerpt(_ text: String, limit: Int) -> String {
        let all = ProjectText.passages(text)
        var total = 0
        var out: [String] = []
        // Evenly spaced, in order: take every k-th passage until it fits, k being the smallest that does.
        let size = all.reduce(0) { $0 + $1.count + 2 }
        guard size > limit, !all.isEmpty else { return all.joined(separator: "\n\n") }
        let keep = max(1, Int(Double(all.count) * Double(limit) / Double(size)))
        for i in 0..<keep {
            let p = all[i * all.count / keep]
            if total + p.count > limit, !out.isEmpty { break }
            out.append(p)
            total += p.count + 2
        }
        return out.joined(separator: "\n\n")
    }

    /// The phrases in a model's answer: one to a line, with what a model adds around a list
    /// (bullets, numbers, quotes, a closing full stop) taken off, and anything that is not a phrase
    /// (a sentence, a line of introduction) left out. `text` is the project, to say how often each
    /// phrase occurs in it: a phrase the model supplied that the text never uses is still offered,
    /// with a count of zero, so the user can see it is a suggestion and not something they wrote.
    static func keywords(from answer: String, in text: String, limit: Int = 12) -> [ProjectKeyword] {
        let haystack = text.lowercased()
        var seen: Set<String> = []
        var out: [ProjectKeyword] = []
        for raw in answer.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            line = line.replacingOccurrences(of: #"^\s*(?:[-*•–]|\d{1,2}[.)])\s*"#, with: "", options: .regularExpression)
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’`*_ .;,"))
            let words = line.split(separator: " ")
            guard !words.isEmpty, words.count <= 5, line.count >= 3, line.count <= 60 else { continue }
            // A line of introduction ("Here are the phrases:") or a sentence is not a phrase.
            if line.hasSuffix(":") || line.contains(". ") { continue }
            let key = line.lowercased()
            guard seen.insert(key).inserted else { continue }
            // Case is kept for an acronym (EEG, fMRI), alone or inside a phrase, and dropped for
            // everything else.
            let phrase = words.map { w in w.filter(\.isUppercase).count >= 2 ? String(w) : w.lowercased() }.joined(separator: " ")
            out.append(ProjectKeyword(phrase: phrase, count: occurrences(of: key, in: haystack),
                                      words: words.count, selected: false))
            if out.count >= limit { break }
        }
        // Ticked to begin with: the first phrases of several words. A word on its own lists too much.
        var ticked = 0
        for i in out.indices where out[i].words > 1 && ticked < 8 {
            out[i].selected = true
            ticked += 1
        }
        return out
    }

    private static func occurrences(of phrase: String, in text: String) -> Int {
        guard !phrase.isEmpty else { return 0 }
        var n = 0
        var from = text.startIndex
        while let r = text.range(of: phrase, range: from..<text.endIndex) {
            n += 1
            from = r.upperBound
        }
        return n
    }
}
