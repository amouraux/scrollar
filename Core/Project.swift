import Foundation

// A research project in the user's own words: a grant proposal, a thesis plan, an abstract. It is
// read on the device and never sent anywhere. It does two things: its passages stand for what the
// user is into, as a library does, and the phrases it keeps coming back to are offered as keywords
// to follow. Pure and tested; the screens are in SettingsView.swift.

/// A project the user pasted, with a title they can change. Device-local like the library file: a proposal
/// is the user's, and may be confidential. Several can be kept, each used for ranking or not.
struct ProjectFile: Codable, Equatable, Identifiable {
    var id: String
    /// What the user calls it.
    var name: String
    var text: String
    /// ISO 8601, when it was pasted.
    var addedAt: String
    /// Whether its passages count toward which papers are close to the user's work.
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, text: String, addedAt: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.text = text
        self.addedAt = addedAt
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, name, text, addedAt, enabled }

    /// Tolerant like every stored type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (ProjectText.suggestedTitle(text) ?? "Project")
        addedAt = (try? c.decodeIfPresent(String.self, forKey: .addedAt)) ?? ""
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    /// The projects in a stored file: a list, or the single project an earlier version kept, whose name was
    /// the first words of its text and is replaced by a title the text suggests.
    static func decodeList(_ data: Data) -> [ProjectFile] {
        if let list = try? JSONDecoder().decode([ProjectFile].self, from: data) { return list }
        guard var legacy = try? JSONDecoder().decode(ProjectFile.self, from: data) else { return [] }
        if legacy.name == ProjectText.title(legacy.text) { legacy.name = ProjectText.suggestedTitle(legacy.text) ?? "Project" }
        return [legacy]
    }
}

/// A phrase the project keeps coming back to.
struct ProjectKeyword: Equatable, Identifiable {
    var phrase: String
    var count: Int
    var words: Int
    /// Ticked to begin with: a phrase of several words, said more than once. A single word searched
    /// alone lists far too much, so it is offered and never ticked.
    var selected: Bool
    var id: String { phrase.lowercased() }
}

enum ProjectText {
    /// Longer than this is a thesis, not a proposal; what follows is not read.
    static let maxCharacters = 80_000
    /// A passage is a few sentences: the sentence model reads the first and the last few, so a
    /// longer one would lose its middle.
    static let passageSize = 450
    /// Embedding is the slow part of ranking, so a long text is thinned, evenly, rather than cut.
    static let maxPassages = 40
    /// How many projects there is room for, each a text read and kept on the device.
    static let maxProjects = 10
    /// Fewer words than this say too little to tell what the project is.
    static let fewestWords = 30

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The first line, shortened: what to call it in the list.
    static func title(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if first.isEmpty { return "Project" }
        return first.count <= 70 ? first : String(first.prefix(60)) + "…"
    }

    /// A title the text itself suggests: its first line, if that is short and reads as a heading (not a
    /// sentence). nil if it does not, and the user is asked.
    static func suggestedTitle(_ text: String) -> String? {
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let words = first.split(separator: " ").count
        guard first.count >= 3, first.count <= 80, words <= 14, !".!?;,:".contains(first.last ?? "x") else { return nil }
        return first
    }

    /// The passages of several projects together, no more than `total`: each is thinned to its share, evenly,
    /// so a long project does not drown a short one.
    static func combinedPassages(_ texts: [String], total: Int = maxPassages) -> [String] {
        guard !texts.isEmpty else { return [] }
        let share = max(total / texts.count, 1)
        return texts.flatMap { text -> [String] in
            let all = passages(text)
            guard all.count > share else { return all }
            return (0..<share).map { all[$0 * all.count / share] }
        }
    }

    // MARK: Passages

    /// Paragraphs, from text that may have been copied out of a PDF: lines wrapped in the middle of
    /// a sentence, words split across a line end with a hyphen, and headings on their own.
    static func paragraphs(_ text: String) -> [String] {
        var t = String(text.prefix(maxCharacters))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "")
        t = t.replacingOccurrences(of: "([a-z])-\n([a-z])", with: "$1$2", options: .regularExpression)
        var out: [String] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { out.append(joined) }
            current = []
        }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, line) in lines.enumerated() {
            if line.isEmpty { flush(); continue }
            // A short line with no full stop, where a paragraph would begin, is a heading: it names
            // the section and says little about the project.
            if current.isEmpty, isHeading(line, nextIsBlank: i + 1 >= lines.count || lines[i + 1].isEmpty) { continue }
            current.append(line)
        }
        flush()
        return out
    }

    /// Text copied from a narrow column also has short lines with no full stop, so a short line is
    /// only a heading if something else says so: a blank line after it, a number before it, very few
    /// words, or capitals on most of them.
    private static func isHeading(_ line: String, nextIsBlank: Bool) -> Bool {
        let words = line.split(separator: " ")
        guard line.count <= 70, words.count <= 10, !".!?;,:".contains(line.last ?? "x") else { return false }
        if nextIsBlank || words.count <= 5 || line.first?.isNumber == true { return true }
        let capitalised = words.filter { $0.first?.isUppercase == true }.count
        return Double(capitalised) / Double(words.count) >= 0.6
    }

    /// The passages that stand for the project: a few sentences each, in prose (not tables of
    /// numbers, reference lists or links), at most `maxPassages`, spread over the whole text.
    static func passages(_ text: String) -> [String] {
        var all: [String] = []
        var seen: Set<String> = []
        for paragraph in paragraphs(text) {
            var sentences: [String] = []
            paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: .bySentences) { s, _, _, _ in
                if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
            }
            var buffer = ""
            func emit() {
                if isProse(buffer), seen.insert(buffer).inserted { all.append(buffer) }
                buffer = ""
            }
            for s in sentences {
                if !buffer.isEmpty, buffer.count + s.count + 1 > passageSize { emit() }
                buffer += (buffer.isEmpty ? "" : " ") + s
            }
            emit()
        }
        guard all.count > maxPassages else { return all }
        return (0..<maxPassages).map { all[$0 * all.count / maxPassages] }
    }

    private static func isProse(_ s: String) -> Bool {
        guard wordCount(s) >= 8 else { return false }
        let lower = s.lowercased()
        if lower.contains("http") || lower.contains("doi.org") || lower.contains("www.") { return false }
        let visible = s.filter { !$0.isWhitespace }
        let letters = visible.filter(\.isLetter).count
        return Double(letters) / Double(max(visible.count, 1)) >= 0.7
    }

    // MARK: Keywords

    // Built from an array: a Set literal with a repeated word traps at launch.
    private static let functionWords = Set<String>([
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "has", "have", "had", "not", "but",
        "can", "its", "into", "than", "their", "these", "those", "which", "between", "about", "above", "across",
        "after", "again", "all", "also", "any", "because", "been", "before", "being", "below", "both", "could", "did",
        "does", "doing", "down", "during", "each", "either", "few", "further", "here", "his", "her", "him", "she",
        "however", "once", "only", "onto", "other", "others", "our", "ours", "out", "over", "own", "same", "should",
        "since", "some", "such", "then", "there", "therefore", "they", "them", "thus", "through", "under", "until",
        "upon", "very", "what", "when", "where", "whether", "while", "who", "whom", "whose", "why", "will", "would",
        "you", "your", "may", "might", "must", "shall", "more", "most", "much", "many", "one", "two", "three", "per",
        "via", "within", "without", "among", "along", "already", "although", "always", "another", "around", "away",
        "based", "due", "even", "every", "first", "second", "third", "given", "well", "still", "often", "rather",
        "several", "using", "used", "use", "uses", "make", "made", "makes", "like", "likely", "get", "gets", "set",
        "sets", "need", "needs", "needed", "take", "takes", "taken", "show", "shows", "shown", "found", "find",
        "finds", "known", "toward", "towards", "whereas", "whilst", "yet", "are", "was", "been", "being", "able",
        "less", "least", "whole", "thereby", "whereby", "hence", "else", "just", "now", "too", "off",
    ])

    /// The words of a proposal that say nothing about its subject.
    private static let filler = Set<String>([
        "study", "studies", "research", "researchers", "project", "projects", "proposal", "aim", "aims", "objective",
        "objectives", "goal", "goals", "approach", "approaches", "work", "works", "package", "packages", "task",
        "tasks", "phase", "phases", "year", "years", "month", "months", "week", "weeks", "result", "results",
        "method", "methods", "methodology", "analysis", "analyses", "data", "dataset", "datasets", "new", "novel",
        "innovative", "important", "significant", "significantly", "key", "main", "major", "overall", "general",
        "specific", "potential", "possible", "current", "previous", "recent", "existing", "various", "different",
        "similar", "number", "level", "levels", "role", "effect", "effects", "impact", "factor", "factors",
        "process", "processes", "understanding", "understand", "investigate", "investigation", "examine",
        "explore", "identify", "determine", "develop", "development", "provide", "propose", "proposed", "expected",
        "outcome", "outcomes", "evidence", "information", "knowledge", "question", "questions", "hypothesis",
        "hypotheses", "student", "students", "university", "department", "institute", "supervisor", "funding",
        "grant", "budget", "cost", "costs", "timeline", "milestone", "milestones", "deliverable", "deliverables",
        "team", "partner", "partners", "collaboration", "dissemination", "publication", "publications", "paper",
        "papers", "patient", "patients", "participant", "participants", "journal", "conference", "thesis", "doctoral", "candidate", "fellowship", "applicant", "figure",
        "table", "section", "chapter", "reference", "references", "example", "including", "include", "includes",
        "assess", "assessment", "evaluate", "evaluation", "test", "tests", "testing", "increase", "increased",
        "improve", "improved", "improvement", "high", "higher", "low", "lower", "large", "small", "good", "better",
        "best", "time", "type", "types", "case", "cases", "way", "ways", "part", "parts", "area", "areas", "field",
        "fields", "problem", "problems", "issue", "issues", "state", "theory", "theories", "framework",
    ])

    private struct Token {
        var raw: String
        var low: String
        /// A word that can open or close a phrase.
        var content: Bool
        var connector: Bool
        var acronym: Bool
    }

    private static func tokenise(_ raw: String) -> Token? {
        var word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-'’"))
        if word.hasSuffix("’s") || word.hasSuffix("'s") { word = String(word.dropLast(2)) }
        guard !word.isEmpty else { return nil }
        let letters = word.filter(\.isLetter).count
        let low = word.lowercased()
        let uppers = word.filter(\.isUppercase).count
        // EEG, fMRI, COVID-19: two capitals or more. A capital that only begins a sentence is not one.
        let acronym = letters >= 2 && uppers >= 2
        let isFunction = functionWords.contains(low) || filler.contains(low)
        return Token(raw: word, low: low,
                     content: letters >= 3 && !isFunction,
                     connector: low == "of",
                     acronym: acronym)
    }

    /// Where a phrase cannot continue: every mark that ends a clause.
    private static let breaks = CharacterSet(charactersIn: ",.;:()[]{}\"“”!?/\\|•–—")

    private static func runs(_ text: String) -> [[Token]] {
        let flat = paragraphs(text).joined(separator: ". ")
        var out: [[Token]] = []
        var run: [Token] = []
        func close() { if !run.isEmpty { out.append(run); run = [] } }
        for piece in flat.components(separatedBy: breaks) {
            for raw in piece.split(whereSeparator: { $0.isWhitespace }) {
                if let t = tokenise(String(raw)) { run.append(t) } else { close() }
            }
            close()
        }
        return out
    }

    /// One form for singular and plural, for counting only.
    private static func stem(_ w: String) -> String {
        if w.count > 5, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }

    /// The phrases a project keeps returning to, to offer as keywords: several words first (said
    /// more than once, and not just a longer way of saying a shorter one already chosen), then
    /// single words that are long and frequent. Counted by plain frequency and filtered against
    /// the words every proposal uses; there is no model in it, so it is predictable and can be tested.
    static func keywords(_ text: String, limit: Int = 18) -> [ProjectKeyword] {
        struct Entry { var display: String; var words: [String]; var count: Int }
        var table: [String: Entry] = [:]
        for run in runs(text) {
            for n in 1...3 where run.count >= n {
                for i in 0...(run.count - n) {
                    let window = Array(run[i..<(i + n)])
                    guard window.first!.content, window.last!.content else { continue }
                    if n == 3, !(window[1].content || window[1].connector) { continue }
                    if n == 2, !window[1].content { continue }
                    let words = window.map { stem($0.low) }
                    let key = words.joined(separator: " ")
                    if var e = table[key] { e.count += 1; table[key] = e; continue }
                    table[key] = Entry(display: window.map { $0.acronym ? $0.raw : $0.low }.joined(separator: " "),
                                       words: words, count: 1)
                }
            }
        }

        func contains(_ outer: [String], _ inner: [String]) -> Bool {
            guard inner.count < outer.count else { return false }
            return (0...(outer.count - inner.count)).contains { Array(outer[$0..<($0 + inner.count)]) == inner }
        }
        func weight(_ n: Int) -> Double { n == 1 ? 1 : n == 2 ? 2 : 2.5 }

        let candidates = table.values.filter { e in
            switch e.words.count {
            case 1:
                let word = e.display
                let acronym = word.count >= 3 && word.filter(\.isUppercase).count >= 2
                return acronym ? e.count >= 2 : (e.count >= 3 && word.count >= 6)
            default:
                return e.count >= 2
            }
        }.sorted {
            let (a, b) = (Double($0.count) * weight($0.words.count), Double($1.count) * weight($1.words.count))
            return a != b ? a > b : $0.display < $1.display
        }

        var chosen: [Entry] = []
        for c in candidates {
            // A longer phrase that only extends one already chosen finds nothing new.
            if chosen.contains(where: { contains(c.words, $0.words) }) { continue }
            // A shorter one inside a chosen phrase is redundant unless it is used far more alone.
            if chosen.contains(where: { contains($0.words, c.words) && Double(c.count) < 1.5 * Double($0.count) }) { continue }
            chosen.append(c)
        }
        let phrases = chosen.filter { $0.words.count > 1 }.prefix(max(limit * 2 / 3, 1))
        let singles = chosen.filter { $0.words.count == 1 }.prefix(max(limit - phrases.count, 0))
        var ticked = 0
        return (Array(phrases) + Array(singles)).map { e in
            let tick = e.words.count > 1 && ticked < 6
            if tick { ticked += 1 }
            return ProjectKeyword(phrase: e.display, count: e.count, words: e.words.count, selected: tick)
        }
    }
}
