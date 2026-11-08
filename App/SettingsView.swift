import SwiftUI
import UniformTypeIdentifiers

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
    @AppStorage("showCovers") private var showCovers = true
    @State private var creatingSyncFile = false
    @State private var joiningSyncFile = false
    @State private var suggesting = false

    var body: some View {
        @Bindable var model = appModel
        NavigationStack {
            Form {
                Section {
                    TextField("ORCID iD, 0000-0000-0000-0000", text: Binding(
                        get: { model.settings.orcid ?? "" },
                        set: {
                            let typed = $0.trimmingCharacters(in: .whitespaces)
                            // A valid iD is stored in its standard form; anything else as typed.
                            model.settings.orcid = typed.isEmpty ? nil : (Orcid.normalised(typed) ?? typed)
                        }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let typed = model.settings.orcid, Orcid.normalised(typed) == nil {
                        Text("That is not a valid ORCID iD.").font(.footnote).foregroundStyle(.orange)
                    }
                    Toggle("Learn from publications", isOn: $model.settings.useMyPublications)
                    NavigationLink {
                        ProfileSourcesView()
                    } label: {
                        LabeledContent("Also learn from", value: count(model.settings.profileOrcids.count))
                    }
                    Button("Suggest what to follow…") { suggesting = true }
                } header: {
                    Text("You")
                } footer: {
                    Text("Your publications, and those of anyone you add under Also learn from (a supervisor, say, if you have few papers yet), set what \"close to my work\" means, and \"Cited you\" tells you when someone cites yours. They can suggest what to follow, but nothing is followed unless it is in the Follow lists below, where you can remove it.")
                }

                Section {
                    entityLink("Topics", kind: .topics, items: $model.settings.followedTopics,
                               explanation: "Papers OpenAlex files under a topic (each paper has up to three). A topic is broad, a few hundred papers a month, so what it finds is ranked with everything else and gets a small bonus, not listed in full. Searched in OpenAlex; a topic taken from a paper's MeSH headings is searched in Europe PMC.")
                    entityLink("Journals", kind: .sources, items: $model.settings.followedJournals, byName: true,
                               explanation: "Everything these journals publish in your look-back window, newest first, under \"From what you follow\". Large general journals publish a lot: remove any you do not want in full.")
                    entityLink("Researchers", kind: .authors, items: $model.settings.followedAuthors, byName: true,
                               explanation: "Every paper where this person appears anywhere in the author list, under \"From what you follow\". Chosen from the search, they are matched by OpenAlex id; added by name, they are searched in Europe PMC and a namesake may slip in.")
                    entityLink("Institutions", kind: .institutions, items: $model.settings.followedInstitutions, byName: true,
                               explanation: "Papers with an author at this institution or one of its departments or hospitals. An institution publishes in every field, so what it finds is ranked with everything else and gets a small bonus, not listed in full.")
                    entityLink("Funders", kind: .funders, items: $model.settings.followedFunders, byName: true,
                               explanation: "Papers acknowledging this funder. A funder's papers are many and mixed, so what it finds is ranked with everything else and gets a small bonus, not listed in full.")
                    NavigationLink {
                        KeywordListView(rules: $model.settings.followedKeywords)
                    } label: {
                        LabeledContent("Keywords", value: count(model.settings.followedKeywords.count))
                    }
                    Toggle("Show everything I follow in its own section", isOn: $model.settings.followSection)
                } header: {
                    Text("Follow")
                } footer: {
                    Text("Each follow searches for new papers. With the section on, every paper that a journal, a researcher or a keyword you follow found is listed under \"From what you follow\", newest first, with no cut-off. Topics, institutions and funders are too broad to list in full, so what they find is ranked with all the rest and gets a small bonus. With the section off, everything is ranked.")
                }

                Section("Mute") {
                    entityLink("Journals", kind: .sources, items: $model.settings.mutedJournals, byName: true,
                               explanation: "Papers from these journals are removed before ranking, wherever they were found, including under Cited you.")
                    entityLink("Researchers", kind: .authors, items: $model.settings.mutedAuthors,
                               explanation: "Papers with this person anywhere in the author list are removed. Matched by OpenAlex id, so papers that came only from Europe PMC are not affected.")
                    entityLink("Topics", kind: .topics, items: $model.settings.mutedTopics,
                               explanation: "Papers OpenAlex files under any of these topics are removed. Matched by OpenAlex topic id, so papers that came only from Europe PMC are not affected.")
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
                    VStack(alignment: .leading) {
                        Text("Prefer high-impact journals")
                        Slider(value: $model.settings.impactWeight, in: 0...1)
                        HStack {
                            Text("Ignore").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Strongly").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Prefer authors with a high h-index")
                        Slider(value: $model.settings.authorWeight, in: 0...1)
                        HStack {
                            Text("Ignore").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Strongly").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Time and balance")
                } footer: {
                    Text("The h-index is that of the author(s) heading each post (see Posts), taken from OpenAlex's own record of each author, so it can be wrong for common names. It favours established researchers over early-career ones, and varies by field. Authors with no figure are neither favoured nor penalised. Impact is OpenAlex's two-year mean citedness: how often a journal's recent papers are cited. It is an open measure close to the impact factor, which is Clarivate's and not available here. Preprints and journals without a figure are neither favoured nor penalised.")
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
                    Picker("Post is headed by", selection: $model.settings.byline) {
                        ForEach(BylineChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Show the journal on each post", isOn: $showCovers)
                } header: {
                    Text("Posts")
                } footer: {
                    Text("Badges show initials: open scholarly data has no author photographs. Which end of the author list leads depends on your field. The h-index option below follows this choice: the higher of the two when both are shown. The picture carries the journal's name.")
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
                    if let name = model.syncFileName {
                        LabeledContent("File", value: name)
                        LabeledContent("Status", value: syncStatusText)
                        Button("Sync now") { Task { await model.syncNow(rearrange: true) } }
                        Button("Stop syncing", role: .destructive) { model.stopSyncing() }
                    } else {
                        Button("Start syncing, creating the file…") { creatingSyncFile = true }
                        Button("Join a file made on another device…") { joiningSyncFile = true }
                    }
                    if case .problem(let message) = model.syncStatus {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Sync between devices")
                } footer: {
                    Text("Make the file in iCloud Drive on one device, then on each other device join that same file. Follows, mutes, keywords, sliders, saved and hidden papers and what you have read are shared and merged, so nothing is lost if you change things on two devices. The OpenAlex key and the feed itself stay on each device.")
                }

                Section {
                    Toggle("Europe PMC and PubMed", isOn: $model.settings.useEuropePMC)
                    Toggle("OpenAlex", isOn: $model.settings.useOpenAlex)
                    if model.settings.useOpenAlex {
                        SecureField("OpenAlex key (free, optional)", text: $model.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Link("Get a free key", destination: URL(string: "https://openalex.org/settings/api")!)
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Europe PMC covers PubMed and the preprint servers for biomedicine and needs nothing. OpenAlex covers every field and adds topics, authors by id, the impact and h-index options and more complete lists of your papers; it needs your own free key, which stays in this device's Keychain and is sent only to OpenAlex. A paper found by both is shown once.")
                }
            }
            .navigationTitle("Tune")
            .fileExporter(isPresented: $creatingSyncFile,
                          document: SyncFileDocument(data: creatingSyncFile ? model.initialSyncData() : Data()),
                          contentType: .json, defaultFilename: "Scrollar sync") { result in
                if case .success(let url) = result { Task { await model.adoptSyncFile(url) } }
            }
            .sheet(isPresented: $suggesting) { SuggestionsView() }
            .fileImporter(isPresented: $joiningSyncFile, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { Task { await model.adoptSyncFile(url) } }
            }
        }
    }

    private func entityLink(_ title: String, kind: OpenAlexClient.EntityKind, items: Binding<[Entity]>,
                            byName: Bool = false, explanation: String? = nil) -> some View {
        NavigationLink {
            EntityListView(title: title, kind: kind, items: items, byName: byName, explanation: explanation)
        } label: {
            LabeledContent(title, value: count(items.wrappedValue.count))
        }
    }

    private var syncStatusText: String {
        switch appModel.syncStatus {
        case .off: return "Off"
        case .syncing: return "Syncing…"
        case .idle(let date): return date.map { "Synced " + $0.formatted(.relative(presentation: .named)) } ?? "Ready"
        case .problem: return "Problem"
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
    /// Whether a name can be typed in and searched by Europe PMC, for when there is
    /// no OpenAlex key or OpenAlex does not know it.
    var byName = false
    /// What this list does to the feed, in plain words, under the list.
    var explanation: String?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("Nothing yet. Tap Add to search.").foregroundStyle(.secondary)
                }
                ForEach(items, id: \.id) { Text($0.name) }
                    .onDelete { items.remove(atOffsets: $0) }
            } footer: {
                if let explanation { Text(explanation) }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            EntitySearchSheet(kind: kind, title: title, byName: byName, chosen: items) { entity in
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
    var byName = false
    let chosen: [Entity]
    let pick: (Entity) -> Void

    @State private var query = ""
    @State private var results: [OpenAlexClient.EntityHit] = []
    @State private var failure: String?
    @State private var added: Set<String> = []

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var nameHint: String {
        switch kind {
        case .authors: return "Searched in Europe PMC by name; write it as it appears in PubMed, like Mouraux A"
        case .sources: return "Searched in Europe PMC by journal name"
        default: return "Searched in Europe PMC by name"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.orange) }
                if !model.usesOpenAlex {
                    Text("Searching needs OpenAlex and its free key. You can still add a name, which Europe PMC searches for.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if byName, trimmedQuery.count >= 2 {
                    let id = SourceRouting.namedID(trimmedQuery)
                    let done = added.contains(id) || chosen.contains { $0.id == id }
                    Button {
                        pick(Entity(id: id, name: trimmedQuery))
                        added.insert(id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add “\(trimmedQuery)” by name").foregroundStyle(.primary)
                                Text(nameHint).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if done { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .buttonStyle(.plain)
                }
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
                if results.isEmpty, query.count >= 2, failure == nil, !byName {
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
                guard !Task.isCancelled, model.usesOpenAlex else { results = []; return }
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
