import Foundation

/// Whose name stands at the head of a post. Open scholarly data holds no
/// photographs of people and no institutional logos we may reuse, so the badge
/// is the person's initials on a colour that is always the same for that name.
///
/// First or last is the reader's choice because the convention differs by field:
/// in the life sciences the last author leads the lab; in much of physics and
/// computing the first author did the work.
enum BylineChoice: String, CaseIterable {
    case last, first

    var label: String {
        switch self {
        case .last: return "Last author (the lab)"
        case .first: return "First author"
        }
    }
}

struct Byline: Equatable {
    var name: String
    var institution: String?
    var initials: String
    /// 0...1, from the name, so the same person has the same colour everywhere.
    var hue: Double

    static func of(_ paper: Paper, choice: BylineChoice) -> Byline? {
        guard let name = (choice == .last ? paper.authors.last : paper.authors.first), !name.isEmpty else { return nil }
        // A one-author paper has one answer whichever is asked for.
        let institution = (choice == .last ? paper.lastInstitution : paper.firstInstitution)
        return Byline(name: name, institution: institution, initials: initials(name), hue: hue(for: name))
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
