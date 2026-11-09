import SwiftUI

/// What is the thumb about? The things a paper has that could be why: the keyword that found it, its journal, its
/// authors, its topics, each with the level it has now. Each one chosen moves one level, up or down, in the list
/// the user can read under Follow and mute, Levels. None chosen: the thumb is about this paper alone.
struct ThumbSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.ThumbRequest
    @State private var chosen: Set<String> = []
    @State private var dontAsk = false
    @State private var started = false

    private var up: Bool { request.up }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Html.plain(request.paper.title)).font(.subheadline).lineLimit(3)
                }
                Section {
                    if request.candidates.isEmpty {
                        Text("Nothing to name: this paper has no keyword, journal, author or topic that can be raised or lowered, so the thumb is about this paper alone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(request.candidates, id: \.ref.key) { candidate in
                        Button {
                            if chosen.contains(candidate.ref.key) { chosen.remove(candidate.ref.key) } else { chosen.insert(candidate.ref.key) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chosen.contains(candidate.ref.key) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen.contains(candidate.ref.key) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.ref.name).foregroundStyle(.primary)
                                    Text("\(candidate.ref.kind.singular) · now \(candidate.level.title)\(arrow(candidate))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(up ? "What do you like about it?" : "What do you not like about it?")
                } footer: {
                    Text("Each one you choose moves one level \(up ? "up" : "down"). You can see and change them under Tune, Follow and mute, Levels. Choose none and the thumb is about this paper alone.")
                }
                Section {
                    Toggle("Next time, use the first reason without asking", isOn: $dontAsk)
                } footer: {
                    Text("It can be turned back on under Tune, Ranking, Your feedback.")
                }
            }
            .navigationTitle(up ? "For me" : "Not for me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(label) { answer() }
                }
            }
            .onAppear {
                guard !started else { return }
                started = true
                chosen = ThumbBasis.preselected(request.candidates, paper: request.paper)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var label: String {
        chosen.isEmpty ? "Just this paper" : (up ? "Promote \(chosen.count)" : "Demote \(chosen.count)")
    }

    /// Where the one step would take it, so that the effect is not a surprise.
    private func arrow(_ candidate: ThumbBasis.Candidate) -> String {
        guard chosen.contains(candidate.ref.key) else { return "" }
        let allowed = candidate.ref.kind.levels
        guard let i = allowed.firstIndex(of: candidate.level) ?? allowed.firstIndex(where: { $0 >= candidate.level }) else { return "" }
        let next = allowed[min(max(i + (up ? 1 : -1), 0), allowed.count - 1)]
        return next == candidate.level ? " (at the limit)" : " → \(next.title)"
    }

    private func answer() {
        if dontAsk { model.settings.asksThumbBasis = false }
        let refs = request.candidates.filter { chosen.contains($0.ref.key) }.map(\.ref)
        dismiss()
        model.applyThumb(request.paper, up: up, chosen: refs)
    }
}
