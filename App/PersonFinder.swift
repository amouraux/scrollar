import SwiftUI

/// Find someone's ORCID iD by their name: the user's own, or a supervisor's. The candidates are told
/// apart by institution, works and a recent paper, and several people with one name are said to be
/// several people. Choosing one hands back an iD whose check character has been verified.
struct PersonFinderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// "Find your ORCID iD" or "Find them".
    let title: String
    let namePrompt: String
    let pick: (PersonCandidate) -> Void

    @State private var name = ""
    @State private var searching = false
    @State private var outcome: PersonSearchOutcome?
    @State private var searchedFor = ""

    private var parsed: PersonName? { PersonName.parse(name) }
    private var sourcesOn: Bool { model.settings.useEuropePMC || model.usesOpenAlex }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(namePrompt, text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button { search() } label: {
                        HStack { Text(searching ? "Searching…" : "Search"); if searching { ProgressView() } }
                    }
                        .disabled(parsed == nil || searching || !sourcesOn)
                } footer: {
                    if searching {
                        Text("Europe PMC is sometimes slow: this can take up to half a minute.")
                    } else if !sourcesOn {
                        Text("No source that can search by name is on. Turn on Europe PMC in Tune, Sources.").foregroundStyle(.orange)
                    } else if parsed == nil, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Type a first and a last name: a last name alone matches too many people.").foregroundStyle(.orange)
                    } else {
                        Text("The name is sent to Europe PMC" + (model.usesOpenAlex ? " and OpenAlex" : "") + ", and nowhere else. ORCID itself is not asked.")
                    }
                }

                if let outcome {
                    Section {
                        ForEach(outcome.candidates) { person in
                            Button { choose(person) } label: { row(person) }
                                .buttonStyle(.plain)
                        }
                        ForEach(outcome.problems, id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                    } header: {
                        Text("Matches for \(searchedFor)")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(outcome.verdict)
                            if let url = OrcidLookup.pageURL(name: searchedFor) {
                                Link("Look on orcid.org", destination: url)
                            }
                            if !model.usesOpenAlex {
                                Button("Add an OpenAlex key…") { dismiss(); model.openTune(.sources) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ person: PersonCandidate) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.body.weight(.semibold))
                if !person.summaryLine.isEmpty { Text(person.summaryLine).font(.subheadline).foregroundStyle(.secondary) }
                if let latest = person.latestLine { Text(latest).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                Text(person.orcid).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func search() {
        guard let parsed, !searching, sourcesOn else { return }
        searching = true
        searchedFor = name.trimmingCharacters(in: .whitespaces)
        Task {
            outcome = await PersonSearchClient.run(parsed,
                                                   europePMC: model.settings.useEuropePMC ? EuropePMCClient() : nil,
                                                   openAlex: model.usesOpenAlex ? model.openAlex : nil)
            searching = false
        }
    }

    /// The check character is verified again on the way out, whatever the source said.
    private func choose(_ person: PersonCandidate) {
        guard Orcid.normalised(person.orcid) != nil else { return }
        pick(person)
        dismiss()
    }
}

/// Where a key or a connection is made: what to choose there, then a button that opens the page.
/// The words come from `SetupHelp`, so every screen that asks for a key says the same thing.
struct SetupPageRows: View {
    let page: SetupPage

    var body: some View {
        Text(page.guide).font(.footnote).foregroundStyle(.secondary)
        Link(destination: page.url) {
            Label(page.buttonTitle, systemImage: "arrow.up.right.square")
        }
    }
}
