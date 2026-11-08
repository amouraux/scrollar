import SwiftUI

extension PaperKind {
    var pickerTitle: String {
        switch self {
        case .research: return "Articles"
        case .review: return "Reviews"
        case .caseReport: return "Case reports"
        case .conferenceAbstract: return "Conference abstracts"
        case .preprint: return "Preprints"
        case .commentary: return "Editorials and letters"
        }
    }
}

extension Weight {
    var title: String {
        switch self {
        case .hide: return "Hide"
        case .lower: return "Lower"
        case .normal: return "Normal"
        case .boost: return "Boost"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("byline") private var bylineRaw = BylineChoice.last.rawValue
    @AppStorage("showCovers") private var showCovers = true

    var body: some View {
        @Bindable var model = appModel
        NavigationStack {
            Form {
                Section {
                    TextField("ORCID iD, 0000-0000-0000-0000", text: Binding(
                        get: { model.settings.orcid ?? "" },
                        set: { model.settings.orcid = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Learn from my publications", isOn: $model.settings.useMyPublications)
                } header: {
                    Text("You")
                } footer: {
                    Text("Your papers set what the feed looks for, and tell you when someone cites them.")
                }

                Section("Follow") {
                    entityLink("Topics", kind: .topics, items: $model.settings.followedTopics)
                    entityLink("Journals", kind: .sources, items: $model.settings.followedJournals)
                    entityLink("Researchers", kind: .authors, items: $model.settings.followedAuthors)
                    entityLink("Institutions", kind: .institutions, items: $model.settings.followedInstitutions)
                    entityLink("Funders", kind: .funders, items: $model.settings.followedFunders)
                    NavigationLink {
                        KeywordListView(rules: $model.settings.followedKeywords)
                    } label: {
                        LabeledContent("Keywords", value: count(model.settings.followedKeywords.count))
                    }
                }

                Section("Mute") {
                    entityLink("Journals", kind: .sources, items: $model.settings.mutedJournals)
                    entityLink("Researchers", kind: .authors, items: $model.settings.mutedAuthors)
                    entityLink("Topics", kind: .topics, items: $model.settings.mutedTopics)
                    NavigationLink {
                        MutedWordsView(words: $model.settings.mutedKeywords)
                    } label: {
                        LabeledContent("Words", value: count(model.settings.mutedKeywords.count))
                    }
                }

                Section {
                    ForEach(PaperKind.allCases, id: \.self) { kind in
                        Picker(kind.pickerTitle, selection: Binding(
                            get: { model.settings.weight(for: kind) },
                            set: { model.settings.setWeight($0, for: kind) })) {
                            ForEach(Weight.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                } header: {
                    Text("Kinds of paper")
                } footer: {
                    Text("Hide removes them. Lower pushes them down the feed. Boost brings them up.")
                }

                Section {
                    Picker("Look back", selection: $model.settings.daysBack) {
                        ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Prefer newer papers")
                        Slider(value: $model.settings.recency, in: 0...1)
                    }
                    VStack(alignment: .leading) {
                        Text("Stay close to my work")
                        Slider(value: $model.settings.closeness, in: 0...1)
                        HStack {
                            Text("What I follow").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("My own field").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Time and balance")
                }

                Section {
                    Picker("Forget unread papers after", selection: $model.settings.seenExpiryDays) {
                        ForEach([3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    Toggle("Show papers I have read", isOn: $model.settings.showReadPapers)
                } header: {
                    Text("Seen and read")
                } footer: {
                    Text("A paper you scrolled past sinks below the new ones, then drops out. A paper you open or read in full leaves the feed and is kept under Saved, Read.")
                }

                Section {
                    Picker("Post is headed by", selection: $bylineRaw) {
                        ForEach(BylineChoice.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Show the journal on each post", isOn: $showCovers)
                } header: {
                    Text("Posts")
                } footer: {
                    Text("Badges show initials: open scholarly data has no author photographs. Which end of the author list leads depends on your field. The picture carries the journal's name.")
                }

                Section("Content") {
                    Toggle("Only papers with an abstract", isOn: $model.settings.requireAbstract)
                    Toggle("Only open access", isOn: $model.settings.openAccessOnly)
                    TextField("Languages, e.g. en, fr (empty for any)", text: Binding(
                        get: { model.settings.languages.joined(separator: ", ") },
                        set: { model.settings.languages = splitList($0) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    LabeledContent("Saved", value: "\(model.settings.feedback.saved.count)")
                    LabeledContent("Hidden", value: "\(model.settings.feedback.hidden.count)")
                    if !model.settings.feedback.hidden.isEmpty {
                        Button("Show hidden papers again", role: .destructive) {
                            model.settings.feedback.hidden = []
                        }
                    }
                } header: {
                    Text("What you have told it")
                } footer: {
                    Text("Saved papers make the feed look for more like them. Hidden papers never come back.")
                }

                Section {
                    SecureField("OpenAlex key", text: $model.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("Get a free key", destination: URL(string: "https://openalex.org/settings/api")!)
                } header: {
                    Text("Data source")
                } footer: {
                    Text("Papers come from OpenAlex and PubMed. The key is free, stays in this device's Keychain, and is sent only to OpenAlex.")
                }
            }
            .navigationTitle("Tune")
        }
    }

    private func entityLink(_ title: String, kind: OpenAlexClient.EntityKind, items: Binding<[Entity]>) -> some View {
        NavigationLink {
            EntityListView(title: title, kind: kind, items: items)
        } label: {
            LabeledContent(title, value: count(items.wrappedValue.count))
        }
    }

    private func count(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }
}

func splitList(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - Things picked by name

struct EntityListView: View {
    let title: String
    let kind: OpenAlexClient.EntityKind
    @Binding var items: [Entity]
    @State private var adding = false

    var body: some View {
        List {
            if items.isEmpty {
                Text("Nothing yet. Tap Add to search.").foregroundStyle(.secondary)
            }
            ForEach(items, id: \.id) { Text($0.name) }
                .onDelete { items.remove(atOffsets: $0) }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            EntitySearchSheet(kind: kind, title: title, chosen: items) { entity in
                if !items.contains(entity) { items.append(entity) }
            }
        }
    }
}

struct EntitySearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: OpenAlexClient.EntityKind
    let title: String
    let chosen: [Entity]
    let pick: (Entity) -> Void

    @State private var query = ""
    @State private var results: [OpenAlexClient.EntityHit] = []
    @State private var failure: String?
    @State private var added: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.orange) }
                ForEach(results) { hit in
                    let done = added.contains(hit.id) || chosen.contains(hit.entity)
                    Button {
                        pick(hit.entity)
                        added.insert(hit.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.entity.name).foregroundStyle(.primary)
                                if let hint = hit.hint {
                                    Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if hit.worksCount > 0 {
                                    Text("\(hit.worksCount.formatted()) works").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if done { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if results.isEmpty, query.count >= 2, failure == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(title.lowercased())")
            .textInputAutocapitalization(.never)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Wait for a pause in typing, and let a newer query cancel this one.
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                do {
                    results = try await model.openAlex.search(kind, query: query)
                    failure = nil
                } catch is CancellationError {
                } catch {
                    failure = model.hasKey ? "Search failed: \(error)" : "Add your OpenAlex key first."
                }
            }
        }
    }
}

// MARK: - Keywords

struct KeywordListView: View {
    @Binding var rules: [KeywordRule]
    @State private var adding = false
    @State private var newPhrase = ""

    var body: some View {
        List {
            if rules.isEmpty {
                Text("Nothing yet. A phrase is searched in titles and abstracts.").foregroundStyle(.secondary)
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                NavigationLink {
                    KeywordRuleEditor(rule: $rules[index])
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.phrase)
                        if !rule.alsoRequire.isEmpty || !rule.exclude.isEmpty {
                            Text(detail(rule)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { rules.remove(atOffsets: $0) }
        }
        .navigationTitle("Keywords")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { newPhrase = ""; adding = true }
            }
        }
        .alert("New keyword", isPresented: $adding) {
            TextField("e.g. predictive coding", text: $newPhrase)
            Button("Add") {
                let phrase = newPhrase.trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty, !rules.contains(where: { $0.phrase == phrase }) {
                    rules.append(KeywordRule(phrase: phrase))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func detail(_ rule: KeywordRule) -> String {
        var parts: [String] = []
        if !rule.alsoRequire.isEmpty { parts.append("also: " + rule.alsoRequire.joined(separator: ", ")) }
        if !rule.exclude.isEmpty { parts.append("not: " + rule.exclude.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

struct KeywordRuleEditor: View {
    @Binding var rule: KeywordRule

    var body: some View {
        Form {
            Section("Phrase") {
                TextField("Phrase", text: $rule.phrase)
            }
            Section {
                TextField("e.g. EEG, humans", text: Binding(
                    get: { rule.alsoRequire.joined(separator: ", ") },
                    set: { rule.alsoRequire = splitList($0) }))
            } header: {
                Text("Must also contain")
            } footer: {
                Text("Separate with commas. Every one must appear in the title or abstract.")
            }
            Section {
                TextField("e.g. rat, mouse", text: Binding(
                    get: { rule.exclude.joined(separator: ", ") },
                    set: { rule.exclude = splitList($0) }))
            } header: {
                Text("Must not contain")
            } footer: {
                Text("Papers found only through this keyword are dropped if any of these appear.")
            }
        }
        .navigationTitle(rule.phrase)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MutedWordsView: View {
    @Binding var words: [String]
    @State private var adding = false
    @State private var newWord = ""

    var body: some View {
        List {
            if words.isEmpty {
                Text("Nothing yet. A paper with one of these words in its title or abstract is hidden.")
                    .foregroundStyle(.secondary)
            }
            ForEach(words, id: \.self) { Text($0) }
                .onDelete { words.remove(atOffsets: $0) }
        }
        .navigationTitle("Muted words")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { newWord = ""; adding = true }
            }
        }
        .alert("Mute a word", isPresented: $adding) {
            TextField("e.g. traditional chinese medicine", text: $newWord)
            Button("Add") {
                let word = newWord.trimmingCharacters(in: .whitespaces)
                if !word.isEmpty, !words.contains(word) { words.append(word) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
