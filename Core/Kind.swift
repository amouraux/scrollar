import Foundation

enum PaperKind: String {
    case research, review, caseReport, conferenceAbstract, preprint, commentary

    var label: String {
        switch self {
        case .research: return "article"
        case .review: return "review"
        case .caseReport: return "case report"
        case .conferenceAbstract: return "conference abstract"
        case .preprint: return "preprint"
        case .commentary: return "commentary"
        }
    }
}

extension Paper {
    /// What kind of paper this is. PubMed's indexing wins when we have it; for
    /// the rest (no PMID: preprints, engineering, most non-biomedical work) the
    /// title and venue have to do.
    var kind: PaperKind {
        let types = Set(pubmedTypes.map { $0.lowercased() })
        if types.contains("case reports") { return .caseReport }
        if types.contains("congress") || types.contains("meeting abstract") { return .conferenceAbstract }
        if !types.isDisjoint(with: Paper.commentaryTypes) { return .commentary }
        if !types.isDisjoint(with: ["review", "systematic review", "meta-analysis"]) { return .review }
        if types.contains("preprint") { return .preprint }

        if looksLikeConferenceAbstract { return .conferenceAbstract }
        if looksLikeCaseReport { return .caseReport }

        switch openAlexType {
        case "review": return .review
        // OpenAlex also types a published paper "preprint" when it links it to its
        // preprint record. If the place it appeared is a journal, it is the journal article.
        case "preprint": return sourceType == "journal" ? .research : .preprint
        case "editorial", "letter", "erratum", "retraction", "paratext": return .commentary
        default: return .research
        }
    }

    private static let commentaryTypes: Set<String> = [
        "editorial", "letter", "comment", "news", "published erratum",
        "retraction of publication", "retracted publication", "interview", "biography",
    ]

    // "Proceedings" is not on this list on purpose: PNAS is a journal.
    private static let venueMarkers = ["abstracts", "annual meeting", "congress", "symposium", "conference on"]

    // Poster and oral numbering: "P-452:", "PO123.", "OA12:". The prefixes are
    // listed because a looser pattern also catches "IL-6: a key cytokine".
    private static let posterNumber = try! NSRegularExpression(
        pattern: #"^(P|PO|PS|PP|OA|OP|O|MP|SP|LBA|EP|TP|FP)[- ]?\d{2,4}\s*[:.]"#)

    private var looksLikeConferenceAbstract: Bool {
        if sourceType == "conference" { return true }
        if let venue = journal?.lowercased(), Paper.venueMarkers.contains(where: venue.contains) { return true }
        let range = NSRange(title.startIndex..., in: title)
        return Paper.posterNumber.firstMatch(in: title, range: range) != nil
    }

    private var looksLikeCaseReport: Bool {
        let t = title.lowercased()
        if t.contains("case report") || t.contains("a case of") || t.contains("case presentation") { return true }
        let opening = (abstract ?? "").lowercased().prefix(300)
        return ["we report a case", "we present a case", "we describe a case", "we report a patient",
                "we present a patient", "this case report"].contains { opening.contains($0) }
    }
}
