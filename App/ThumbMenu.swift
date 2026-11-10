import SwiftUI

/// The thumb buttons. A tap opens a short menu of what the thumb could be about (the paper's keywords, journal,
/// authors, topics), and one more tap on a reason applies it: the thumb is recorded on that reason and the feed
/// learns from it (Core/Evidence.swift). With nothing to ask, or when the user said not to ask, or to take back a
/// For me, the tap acts at once.
struct ThumbControl<Content: View>: View {
    @Environment(AppModel.self) private var model
    let paper: Paper
    let up: Bool
    let hint: String
    @ViewBuilder let label: () -> Content

    var body: some View {
        let reasons = model.thumbReasons(for: paper, up: up)
        if reasons.isEmpty {
            Button { model.thumb(paper, up: up) } label: { label() }
                .buttonStyle(.plain)
                .accessibilityHint(hint)
        } else {
            Menu {
                Section(up ? "What do you like most about it?" : "What do you like least about it?") {
                    ForEach(reasons, id: \.ref.key) { reason in
                        Button { model.applyThumb(paper, up: up, chosen: [reason.ref]) } label: {
                            Label(title(reason), systemImage: symbol(reason.ref.kind))
                        }
                    }
                    Button { model.applyThumb(paper, up: up, chosen: []) } label: { Text("Just this paper") }
                }
            } label: { label() }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityHint(hint)
        }
    }

    /// "Migraine · now +0.3": the thing, and what the thumbs have made of it (its kind is the icon).
    private func title(_ reason: ThumbBasis.Candidate) -> String {
        let standing = model.thumbStanding(reason.ref)
        return reason.ref.name + (standing.isEmpty ? "" : " · " + standing)
    }

    private func symbol(_ kind: FacetKind) -> String {
        switch kind {
        case .keyword: return "tag"
        case .journal: return "book.closed"
        case .author: return "person"
        case .topic: return "circle.hexagongrid"
        case .institution: return "building.2"
        case .funder: return "banknote"
        }
    }
}
