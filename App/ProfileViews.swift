import SwiftUI

/// Others whose publications the feed also learns from.
struct ProfileSourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                if model.settings.profileOrcids.isEmpty {
                    Text("Nobody yet.").foregroundStyle(.secondary)
                }
                ForEach(model.settings.profileOrcids, id: \.orcid) { person in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.label.isEmpty ? person.orcid : person.label)
                        if !person.label.isEmpty { Text(person.orcid).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .onDelete { model.settings.profileOrcids.remove(atOffsets: $0) }
            } footer: {
                Text("Their publications are read with yours: they set what \"close to my work\" means and can suggest what to follow. Most useful when you have few papers yet, with a supervisor or a group leader. Their new papers are not hidden from you. Up to three.")
            }
        }
        .navigationTitle("Also learn from")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { adding = true }
                    .disabled(model.settings.profileOrcids.count >= 3)
            }
        }
        .sheet(isPresented: $adding) { AddProfileSourceSheet() }
    }
}

struct AddProfileSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var label = ""
    @State private var found: String?
    @State private var checking = false
    @State private var lookupFailed = false

    private var orcid: String? { Orcid.normalised(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ORCID iD, 0000-0000-0000-0000", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("What to call them, e.g. Supervisor", text: $label)
                } footer: {
                    if orcid == nil, !text.isEmpty {
                        Text("That is not a valid ORCID iD.").foregroundStyle(.orange)
                    } else if checking {
                        Text("Looking them up…")
                    } else if let found {
                        Text("Found: \(found)")
                    } else if lookupFailed {
                        Text("Could not look them up. You can still add the iD.").foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Learn from")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let orcid else { return }
                        let mine = model.settings.orcid.flatMap(Orcid.normalised)
                        if orcid != mine, !model.settings.profileOrcids.contains(where: { $0.orcid == orcid }) {
                            model.settings.profileOrcids.append(ProfileSource(orcid: orcid, label: label.trimmingCharacters(in: .whitespaces)))
                        }
                        dismiss()
                    }
                    .disabled(orcid == nil)
                }
            }
            .task(id: text) {
                found = nil
                lookupFailed = false
                guard let orcid else { return }
                checking = true
                defer { checking = false }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if let name = try? await OrcidClient().name(orcid: orcid) { found = name } else { lookupFailed = true }
            }
        }
    }
}

/// What the user's publications suggest following, to choose from.
struct SuggestionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case failed(String)
        case loaded(AppModel.ProfileSuggestions)
    }

    @State private var phase: Phase = .loading
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Reading your publications…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Could not read them", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                case .loaded(let found):
                    list(found)
                }
            }
            .navigationTitle("From your publications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if case .loaded(let found) = phase {
                        Button("Add \(chosen.count)") {
                            let all = SuggestionKind.allCases.flatMap { found.byKind[$0] ?? [] }
                            model.follow(all.filter { chosen.contains($0.id) })
                            dismiss()
                        }
                        .disabled(chosen.isEmpty)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func list(_ found: AppModel.ProfileSuggestions) -> some View {
        List {
            Section {
                Text("From \(found.paperCount) recent papers by \(found.names.joined(separator: ", ")). What is ticked is recent and recurrent; older things are listed unticked, in case you still follow them. Nothing is followed until you add it, and everything you add can be removed under Follow.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(SuggestionKind.allCases, id: \.self) { kind in
                let items = (found.byKind[kind] ?? []).filter { !model.isFollowed($0) }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in row(item) }
                    } header: {
                        Text(kind.title)
                    } footer: {
                        if let note = Self.note(for: kind) { Text(note) }
                    }
                }
            }
        }
    }

    private func row(_ item: ProfileSuggestion) -> some View {
        Button {
            if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: chosen.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen.contains(item.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.entity.name).foregroundStyle(.primary)
                    Text(evidence(item)).font(.caption).foregroundStyle(.secondary)
                    if let note = item.note { Text(note).font(.caption).foregroundStyle(.orange) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func evidence(_ item: ProfileSuggestion) -> String {
        var parts = ["\(item.count) paper\(item.count == 1 ? "" : "s")", "latest \(item.latestYear)"]
        if item.fromNames.count > 1 || item.fromNames.first != "you" { parts.append("from " + item.fromNames.joined(separator: " and ")) }
        return parts.joined(separator: " · ")
    }

    private static func note(for kind: SuggestionKind) -> String? {
        switch kind {
        case .topic: return "Topics are broad, so what they find is ranked with everything else."
        case .journal: return "Following a journal lists everything it publishes. Untick large general journals."
        case .researcher: return "Following someone lists every paper they appear on, in any field."
        case .institution: return "An institution publishes in every field, so what it finds is ranked, not listed in full."
        case .funder: return "A funder's papers are many and mixed, so what it finds is ranked, not listed in full."
        }
    }

    private func load() async {
        phase = .loading
        do {
            let found = try await model.loadProfileSuggestions()
            chosen = Set(SuggestionKind.allCases.flatMap { found.byKind[$0] ?? [] }.filter { $0.selected && !model.isFollowed($0) }.map(\.id))
            phase = .loaded(found)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
