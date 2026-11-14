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

/// A short name for a current interest, asked of Apple's on-device model when the user gives none. Only the
/// on-device model: the text may be a confidential proposal, and a title is not worth sending it anywhere.
enum InterestTitle {
    static let instructions = """
        You name a text a researcher saved to say what they are interested in now: a grant proposal, \
        an abstract, a paper in progress, a conference programme, notes. Give it a short title, the way \
        they would label a folder: three to seven words naming the scientific subject or question it is \
        about, specific enough to tell it apart from their other interests. Name the subject, not the \
        method alone and not the kind of text: no words such as project, proposal, programme, conference \
        or study unless they are part of a name the text gives. Use only names, dates and years the text \
        itself states; never add one. Answer with the title alone: no quotation marks, no full stop, no \
        other text.
        """

    /// The opening of the text, where a programme or a paper says what it is, and then passages from the rest.
    static func prompt(_ text: String, limit: Int = 3_000) -> String {
        let opening = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        let rest = ProjectBrief.excerpt(text, limit: max(limit - opening.count, 500))
        return "The beginning of the text:\n\n" + opening + (rest.isEmpty ? "" : "\n\nPassages from it:\n\n" + rest)
    }

    /// The title in a model's answer, or nil if it gave something that is not one: what a model wraps around a
    /// title ("Title:", quotes, bold, a full stop) taken off, and a sentence or a paragraph refused. A year the
    /// text never states is taken off too: told not to, the on-device model still added "2024" to a programme
    /// that gave none, so the rule is kept here rather than trusted to the instructions.
    static func clean(_ answer: String, text: String) -> String? {
        guard var line = answer.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        line = line.replacingOccurrences(of: #"^(?i:(?:suggested\s+)?title)\s*:\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’`*_ ."))
        let found = try? NSRegularExpression(pattern: #"\b(?:19|20)\d\d\b"#)
        let years = (found?.matches(in: line, range: NSRange(line.startIndex..., in: line)) ?? [])
            .compactMap { Range($0.range, in: line).map { String(line[$0]) } }
        for year in Set(years) where !text.contains(year) {
            line = line.replacingOccurrences(of: #"\s*[(,–-]?\s*\b"# + year + #"\b\)?"#, with: "", options: .regularExpression)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: " ,–-"))
        let words = line.split(separator: " ").count
        guard line.count >= 3, line.count <= 70, words <= 10, !line.contains(". "), !line.hasSuffix(":") else { return nil }
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
