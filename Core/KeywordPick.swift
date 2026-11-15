import Foundation

// Better keywords from a pasted text without a bigger model. Apple's on-device model is small: asked to
// write phrases it drifts into general words and phrases the text never uses, but asked to choose from
// phrases that are in the text it chooses well. Then OpenAlex says what each chosen phrase is worth (how
// many papers a month use it) and how the literature names the same subject (the keywords it gives the
// papers those phrases find). Only the phrases go to OpenAlex, never the text. Pure, so it is tested;
// the model and the requests are in App/ProjectAI.swift and Core/OpenAlex.swift.

enum KeywordPick {
    /// How much of the text goes with the list: less than when the model writes, as the list takes room.
    static let excerptLimit = 3_000
    static let maxCandidates = 50
    static let maxPicked = 10
    /// How many phrases are searched on OpenAlex to find papers like the text's.
    static let literatureQueries = 4
    static let papersPerQuery = 15

    static let instructions = """
        You help a researcher set up a feed of new papers. You are given passages from a text about their \
        research and a list of phrases found in it. Choose the phrases that name what the research is about: \
        the specific conditions, populations, methods, techniques and technical terms that would find related \
        papers in a title or abstract. Leave out general words, words about the document itself, statistics, \
        places and names. Answer with six to ten phrases copied exactly from the list, the most important \
        first, one per line, and nothing else.
        """

    static func prompt(excerpt: String, candidates: [ProjectKeyword]) -> String {
        "Passages:\n\n" + excerpt + "\n\nPhrases found in the text:\n" + candidates.map(\.phrase).joined(separator: "\n")
    }

    /// What the model chooses from: the counted phrases of several words, the noun phrases a tagger found
    /// at least twice (`nounPhrases`, phrase and count), and the commonest single words, with the
    /// abbreviations the text defines written out. A phrase that differs only by a plural is listed once.
    static func candidates(counted: [ProjectKeyword], nounPhrases: [(phrase: String, count: Int)], text: String,
                           limit: Int = maxCandidates) -> [ProjectKeyword] {
        var raw = counted.filter { $0.words > 1 }
        let nouns = nounPhrases.filter { $0.count >= 2 && !$0.phrase.lowercased().contains("et al") }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.phrase < $1.phrase }.prefix(30)
        raw += nouns.map { ProjectKeyword(phrase: $0.phrase, count: $0.count, words: $0.phrase.split(separator: " ").count, selected: false) }
        raw += counted.filter { $0.words == 1 }.prefix(12)
        let defs = Abbreviations.definitions(in: text)
        var seen: Set<String> = []
        var out: [ProjectKeyword] = []
        for k in raw {
            let phrase = Abbreviations.expand(k.phrase, defs)
            // Six words is a description, not something a title says.
            guard phrase.split(separator: " ").count <= 5, seen.insert(key(phrase)).inserted else { continue }
            out.append(ProjectKeyword(phrase: phrase, count: k.count, words: phrase.split(separator: " ").count, selected: false))
            if out.count >= limit { break }
        }
        return out
    }

    /// The phrases of the model's answer that are on the list, in its order. A line that is not on the list
    /// is dropped: the point of choosing is that nothing invented gets through.
    static func matched(_ answer: String, candidates: [ProjectKeyword], limit: Int = maxPicked) -> [ProjectKeyword] {
        var byKey: [String: ProjectKeyword] = [:]
        for c in candidates where byKey[key(c.phrase)] == nil { byKey[key(c.phrase)] = c }
        var seen: Set<String> = []
        var out: [ProjectKeyword] = []
        for line in ProjectBrief.keywords(from: answer, in: "", limit: 40) {
            let k = key(line.phrase)
            guard let c = byKey[k], seen.insert(k).inserted else { continue }
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }

    /// The chosen phrases first, then what the model wrote unprompted that the text does use (it finds a term
    /// said once, which counting cannot), with what it invented left out. Ticked to begin with: the first
    /// chosen phrases of several words.
    static func combine(picked: [ProjectKeyword], written: [ProjectKeyword], text: String, limit: Int = 14) -> [ProjectKeyword] {
        let defs = Abbreviations.definitions(in: text)
        var seen: Set<String> = []
        var out: [ProjectKeyword] = []
        var ticked = 0
        for var k in picked where seen.insert(key(k.phrase)).inserted {
            k.selected = k.words > 1 && ticked < 8
            if k.selected { ticked += 1 }
            out.append(k)
        }
        for k in written where k.count > 0 {
            let phrase = Abbreviations.expand(asWritten(k.phrase, in: text), defs)
            guard out.count < limit, seen.insert(key(phrase)).inserted else { continue }
            out.append(ProjectKeyword(phrase: phrase, count: k.count, words: phrase.split(separator: " ").count, selected: false))
        }
        return out
    }

    /// Counted over a year: a month says too little about a narrow phrase, where one paper more or less is
    /// the whole difference.
    static let volumeDays = 365
    /// Fewer papers than this in a year and a keyword finds next to nothing: it describes the text perfectly
    /// and is no use as a search ("M1-rTMS induced hypoalgesia").
    static let narrowPerYear = 6

    /// Broad on the same line as Suggest what to follow: hundreds of papers a month.
    static func isBroad(_ perYear: Int) -> Bool { perYear >= ProfileAnalysis.broadKeyword * 12 }
    static func isNarrow(_ perYear: Int) -> Bool { perYear < narrowPerYear }

    /// Each phrase with how many papers a year match it, where known, and a broad or narrow one unticked: a
    /// followed keyword is listed in full, and one that lists hundreds a month buries the rest, while one
    /// that lists nothing only looks useful. `volumes` is by `ProjectKeyword.id`.
    static func checked(_ words: [ProjectKeyword], volumes: [String: Int]) -> [ProjectKeyword] {
        words.map { k in
            var k = k
            k.volume = volumes[k.id] ?? k.volume
            if let v = k.volume, isBroad(v) || isNarrow(v) { k.selected = false }
            return k
        }
    }

    /// Words that carry no subject of their own, left out when a phrase is cut down to its main words.
    private static let connective: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "from", "by", "with", "without", "and", "or", "as",
        "versus", "vs", "via", "during", "after", "before", "following", "using", "induced", "related", "associated",
        "based", "mediated", "dependent", "specific", "driven", "evoked", "elicited", "response", "responses",
    ]

    /// A phrase too narrow to find anything, cut down to its main words: each a term, the phrase becoming a
    /// keyword with the others required, which every source searches as all of them anywhere in the title
    /// or abstract. A hyphenated word with an acronym in it is taken apart, and a short code in it ("M1")
    /// dropped. The longest forms first; the whole phrase is not one of them.
    static func shorterForms(_ phrase: String, limit: Int = 8) -> [(phrase: String, also: [String])] {
        var terms: [String] = []
        for word in phrase.split(separator: " ").map(String.init) {
            let parts = word.split(separator: "-").map(String.init)
            let pieces = parts.count > 1 && parts.contains(where: { $0.filter(\.isUppercase).count >= 2 }) ? parts : [word]
            for p in pieces {
                let bare = p.trimmingCharacters(in: .punctuationCharacters)
                let code = bare.count <= 2 || (bare.count <= 3 && bare.contains(where: \.isNumber))
                guard !code, !connective.contains(bare.lowercased()),
                      !terms.contains(where: { $0.lowercased() == bare.lowercased() }) else { continue }
                terms.append(bare)
            }
        }
        guard terms.count >= 2 else { return [] }
        var out: [[String]] = []
        func combos(_ k: Int, from start: Int, _ chosen: [String]) {
            if chosen.count == k { out.append(chosen); return }
            guard start < terms.count else { return }
            for i in start..<terms.count { combos(k, from: i + 1, chosen + [terms[i]]) }
        }
        for k in stride(from: min(terms.count, 3), through: 2, by: -1) { combos(k, from: 0, []) }
        let whole = phrase.lowercased()
        return out.filter { $0.joined(separator: " ").lowercased() != whole }
            .prefix(limit).map { (phrase: $0[0], also: Array($0.dropFirst())) }
    }

    /// The narrow phrase replaced by its most specific shorter form that is neither narrow nor broad, ticked
    /// if the phrase was; or nil, and the phrase stays as it is, unticked. `volumes` is per form, nil unknown.
    static func shortened(_ k: ProjectKeyword, wasSelected: Bool, forms: [(phrase: String, also: [String])],
                          volumes: [Int?]) -> ProjectKeyword? {
        let usable = zip(forms, volumes).compactMap { form, v -> (form: (phrase: String, also: [String]), volume: Int)? in
            guard let v, !isNarrow(v), !isBroad(v) else { return nil }
            return (form, v)
        }
        guard let best = usable.min(by: { $0.volume < $1.volume }) else { return nil }
        return ProjectKeyword(phrase: best.form.phrase, count: k.count, words: 1 + best.form.also.count,
                              selected: wasSelected, volume: best.volume, also: best.form.also, shortenedFrom: k.phrase)
    }

    /// What to search OpenAlex for, to find papers like the text's: the first ticked phrases, which are the
    /// model's strongest and not broad.
    static func literatureQueries(_ words: [ProjectKeyword]) -> [String] {
        Array(words.filter(\.selected).prefix(literatureQueries).map { ([$0.phrase] + $0.also).joined(separator: " ") })
    }

    /// The keywords OpenAlex gives the papers found, kept where papers found for different phrases agree
    /// (one search alone drifts with any word it shares with another field, as "OA" does with open
    /// access). `found` is, for each phrase searched, each paper's keywords. Leaves out what is already
    /// offered. Unticked: these come from other papers, not from the text.
    static func literature(_ found: [(query: String, keywords: [[String]])], excluding: [String], text: String,
                           limit: Int = 10) -> [ProjectKeyword] {
        let skip = Set(excluding.map(key))
        var papers: [String: Int] = [:]
        var queries: [String: Set<String>] = [:]
        var display: [String: String] = [:]
        for (query, works) in found {
            for keywords in works {
                for raw in Set(keywords.map { tidy($0) }) where !raw.isEmpty {
                    let k = key(raw)
                    papers[k, default: 0] += 1
                    queries[k, default: []].insert(query)
                    if display[k] == nil { display[k] = raw }
                }
            }
        }
        let needed = found.count >= 2 ? 2 : 1
        let haystack = text.lowercased()
        return papers.filter { (queries[$0.key]?.count ?? 0) >= needed && $0.value >= 3 && !skip.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { k, n in
                let phrase = display[k]!
                return ProjectKeyword(phrase: phrase, count: occurrences(phrase.lowercased(), in: haystack),
                                      words: phrase.split(separator: " ").count, selected: false, papers: n)
            }
    }

    /// A phrase as the text writes it, so an acronym the model lowercased ("nssi") gets its capitals back.
    static func asWritten(_ phrase: String, in text: String) -> String {
        guard let r = text.range(of: phrase, options: .caseInsensitive) else { return phrase }
        return tidy(String(text[r]))
    }

    /// A keyword the user typed or edited, ticked, with how often the text uses its main phrase. Words that
    /// must all appear are joined with "+" ("rTMS + analgesia"), as they are shown. Nil for nothing typed.
    /// `from` is the suggestion it was edited from, if it was one.
    static func typed(_ input: String, text: String, from: String? = nil) -> ProjectKeyword? {
        let terms = input.split(separator: "+")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\"“”")) }
            .filter { !$0.isEmpty }
        guard let first = terms.first else { return nil }
        var seen: Set<String> = [first.lowercased()]
        let also = terms.dropFirst().filter { seen.insert($0.lowercased()).inserted }
        let fromKey = from.map { $0.lowercased() }
        return ProjectKeyword(phrase: first, count: occurrences(first.lowercased(), in: text.lowercased()),
                              words: first.split(separator: " ").count + also.count, selected: true, also: Array(also),
                              shortenedFrom: fromKey == ([first] + also).joined(separator: " + ").lowercased() ? nil : from)
    }

    /// One key for a phrase however it is cased or pluralised: "OA responses" and "oa response" are one.
    static func key(_ phrase: String) -> String {
        phrase.lowercased().split(separator: " ").map { w in
            w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : String(w)
        }.joined(separator: " ")
    }

    /// OpenAlex's keywords are title-cased ("Offset Analgesia"); a keyword is shown as a phrase, with an
    /// acronym kept as it is.
    private static func tidy(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).split(separator: " ")
            .map { w in w.filter(\.isUppercase).count >= 2 ? String(w) : w.lowercased() }.joined(separator: " ")
    }

    private static func occurrences(_ phrase: String, in text: String) -> Int {
        guard !phrase.isEmpty else { return 0 }
        var n = 0
        var from = text.startIndex
        while let r = text.range(of: phrase, range: from..<text.endIndex) { n += 1; from = r.upperBound }
        return n
    }
}

/// The abbreviations a text defines, "offset analgesia (OA)", so a phrase such as "OA response" is offered as
/// what the text means by it. Searched as it stands it would find open access and osteoarthritis.
enum Abbreviations {
    static func definitions(in text: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"((?:[A-Za-z][\w-]*\s+){1,6})\(([A-Za-z]{2,8})[);,]"#) else { return [:] }
        var out: [String: String] = [:]
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let wr = Range(m.range(at: 1), in: text), let ar = Range(m.range(at: 2), in: text) else { continue }
            let words = text[wr].split(whereSeparator: \.isWhitespace).map(String.init)
            let abbr = String(text[ar])
            guard out[abbr] == nil, abbr.filter(\.isUppercase).count >= 2 else { continue }
            // Every letter is an initial (fMRI), or all but a plural's s (GBOs), or only the capitals (MeSH).
            let plain = abbr.count > 2 && abbr.hasSuffix("s") ? String(abbr.dropLast()) : abbr
            let spellings = [plain.lowercased(), String(abbr.filter(\.isUppercase).lowercased())]
            search: for letters in spellings where letters.count >= 2 {
                for n in stride(from: min(words.count, letters.count), through: 1, by: -1) {
                    let tail = Array(words.suffix(n))
                    let initials = tail.flatMap { $0.split(separator: "-").compactMap { $0.first?.lowercased() } }.joined()
                    if initials == letters {
                        out[abbr] = tail.joined(separator: " ").lowercased()
                        break search
                    }
                }
            }
        }
        return out
    }

    /// Each word of `phrase` that the text defines, written out, a plural kept plural ("GBOs" stays "GBOs" when
    /// the text defined "GBOs" itself, and "OAs" becomes the plural of what OA is).
    static func expand(_ phrase: String, _ defs: [String: String]) -> String {
        guard !defs.isEmpty else { return phrase }
        return phrase.split(separator: " ").map { w -> String in
            let word = String(w)
            if let long = defs[word] { return long }
            if word.hasSuffix("s"), let long = defs[String(word.dropLast())] { return long + "s" }
            return word
        }.joined(separator: " ")
    }
}
