import Foundation

/// Whose name stands at the head of a post. Open scholarly data holds no
/// photographs of people and no institutional logos we may reuse, so the badge
/// is the person's initials on a colour that is always the same for that name.
///
/// First or last is the reader's choice because the convention differs by field:
/// in the life sciences the last author leads the lab; in much of physics and
/// computing the first author did the work.
enum BylineChoice: String, CaseIterable, Codable {
    case last, first, both

    var label: String {
        switch self {
        case .last: return "Last author (the lab)"
        case .first: return "First author"
        case .both: return "First and last author"
        }
    }
}

struct Byline: Equatable {
    var name: String
    /// Where this person stands in the paper's author list, so their OpenAlex id
    /// can be looked up for muting.
    var index: Int
    var institution: String?
    var initials: String
    /// 0...1, from the name, so the same person has the same colour everywhere.
    var hue: Double

    /// The people a post is headed by: one, or the first and the last. A paper
    /// with a single author has one whichever is asked for.
    static func people(of paper: Paper, choice: BylineChoice) -> [Byline] {
        guard !paper.authors.isEmpty else { return [] }
        let first = person(paper, last: false)
        let last = person(paper, last: true)
        switch choice {
        case .first: return first.map { [$0] } ?? []
        case .last: return last.map { [$0] } ?? []
        case .both:
            let both = [first, last].compactMap { $0 }
            return paper.authors.count > 1 ? both : Array(both.prefix(1))
        }
    }

    private static func person(_ paper: Paper, last: Bool) -> Byline? {
        let index = last ? paper.authors.count - 1 : 0
        guard paper.authors.indices.contains(index), !paper.authors[index].isEmpty else { return nil }
        let name = paper.authors[index]
        return Byline(name: name, index: index,
                      institution: last ? paper.lastInstitution : paper.firstInstitution,
                      initials: initials(name), hue: hue(for: name))
    }

    /// "Ghent University · UCLouvain", or one name where they share it.
    static func places(_ people: [Byline]) -> String? {
        var seen: [String] = []
        for p in people { if let i = p.institution, !seen.contains(i) { seen.append(i) } }
        return seen.isEmpty ? nil : seen.joined(separator: " · ")
    }

    /// "Valéry Legrain" -> "VL", "Ludwig van der Berg" -> "LB", "Madonna" -> "MA".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
            .map { $0.filter { $0.isLetter } }
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "?" }
        guard words.count > 1, let last = words.last else {
            return String(first.prefix(2)).uppercased()
        }
        return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
    }

    static func hue(for name: String) -> Double {
        Double(CachingEmbedder.hash(name.lowercased()) % 360) / 360
    }
}
