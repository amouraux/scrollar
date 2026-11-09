import SwiftUI
import PDFKit
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
    @State private var creatingBackup = false
    @State private var restoringBackup = false
    @State private var pendingRestore: PendingRestore?
    @State private var restoreError: String?

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
                    entityLink("Topics", kind: .topics, items: $model.settings.followedTopics, seedFor: Seed.forTopic,
                               explanation: "Papers OpenAlex files under a topic (each paper has up to three). A topic is broad, a few hundred papers a month, so what it finds is ranked with everything else and gets a small bonus, not listed in full. Searched in OpenAlex; a topic taken from a paper's MeSH headings is searched in Europe PMC.")
                    entityLink("Journals", kind: .sources, items: $model.settings.followedJournals, byName: true,
                               seedFor: { .journal(id: $0.id, name: $0.name) },
                               explanation: "Everything these journals publish in your look-back window is kept in your feed, however low it would score. Large general journals publish a lot: remove any you do not want in full.")
                    entityLink("Researchers", kind: .authors, items: $model.settings.followedAuthors, byName: true,
                               seedFor: { .author(id: $0.id, name: $0.name) },
                               explanation: "Every paper where this person appears anywhere in the author list is kept in your feed, however low it would score. Chosen from the search, they are matched by OpenAlex id; added by name, they are searched in Europe PMC and a namesake may slip in.")
                    entityLink("Institutions", kind: .institutions, items: $model.settings.followedInstitutions, byName: true,
                               seedFor: { .institution(id: $0.id, name: $0.name) },
                               explanation: "Papers with an author at this institution or one of its departments or hospitals. An institution publishes in every field, so what it finds is ranked with everything else and gets a small bonus, not listed in full.")
                    entityLink("Funders", kind: .funders, items: $model.settings.followedFunders, byName: true,
                               seedFor: { .funder(id: $0.id, name: $0.name) },
                               explanation: "Papers acknowledging this funder. A funder's papers are many and mixed, so what it finds is ranked with everything else and gets a small bonus, not listed in full.")
                    NavigationLink {
                        KeywordListView(rules: $model.settings.followedKeywords)
                    } label: {
                        LabeledContent("Keywords", value: count(model.settings.followedKeywords.count))
                    }
                } header: {
                    Text("Follow")
                } footer: {
                    Text("Each follow searches for new papers. Everything that a journal, a researcher or a keyword you follow found is always in your feed, however low it scores. Topics, institutions and funders are too broad for that, so what they find is ranked with all the rest and gets a small bonus.")
                }

                Section {
                    Picker("Order", selection: $model.settings.feedOrder) {
                        ForEach(FeedOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Stepper("Highlights: \(model.settings.highlightCount)", value: $model.settings.highlightCount, in: 0...5)
                    if model.settings.highlightCount > 0 {
                        VStack(alignment: .leading) {
                            Text("Highlight papers in the top \(max(1, Int(((1 - model.settings.highlightCloseness) * 100).rounded())))% closest to my work")
                            Slider(value: $model.settings.highlightCloseness, in: 0.5...0.99)
                            HStack {
                                Text("More highlights").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Only the very closest")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Stepper(model.settings.highlightImpact == 0 ? "Journal impact: ignored"
                                : "Journal impact at least \(Int(model.settings.highlightImpact))",
                                value: $model.settings.highlightImpact, in: 0...50, step: 1)
                        Stepper(model.settings.highlightAuthorH == 0 ? "Author h-index: ignored"
                                : "Author h-index at least \(model.settings.highlightAuthorH)",
                                value: $model.settings.highlightAuthorH, in: 0...200, step: 5)
                    }
                } header: {
                    Text("Order and highlights")
                } footer: {
                    Text("One ranked list puts every paper where its score says, so a paper that cites you, one from a journal you follow and a close match all compete, and the line on each card says why it is there. In sections puts what cites you first, then what you follow, then the rest. Highlights are the few new papers above the feed that are very close to your work and also have something more: a journal or an author as strong as you set, a citation of your work, or something specific you follow. Impact is OpenAlex's two-year mean citedness (a high journal is about 5 or more); the h-index is checked only when the h-index option below has fetched it, for the author you chose under Posts.")
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
                    Stepper("Studied after \(Int(model.settings.dwellSeconds)) seconds",
                            value: $model.settings.dwellSeconds, in: 2...15, step: 1)
                    Toggle("Show papers I have read", isOn: $model.settings.showReadPapers)
                } header: {
                    Text("Seen and read")
                } footer: {
                    Text("A post is seen once it has been on screen for a moment (about a second and a half, at least half of it showing): one you only flick past stays new. A paper you scrolled past sinks below the new ones, then drops out. One that stayed on screen for the number of seconds above, or that you marked For me, counts as studied: it sinks further and drops out after two days at most. The order changes when the feed is refreshed or reopened, never while you scroll. A paper you open or read in full leaves the feed and is kept under Saved, Read.")
                }

                Section {
                    Picker("Post is headed by", selection: $model.settings.byline) {
                        ForEach(BylineChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Journal banner on each post", isOn: $showCovers)
                } header: {
                    Text("Posts")
                } footer: {
                    Text("Badges show initials: open scholarly data has no author photographs. Which end of the author list leads depends on your field. The h-index option below follows this choice: the higher of the two when both are shown. A journal always has the same colour: a banner with its name and subject above the title. Off, the journal is a plain line.")
                }

                Section {
                    Toggle("Only papers with an abstract", isOn: $model.settings.requireAbstract)
                    Toggle("Only open access", isOn: $model.settings.openAccessOnly)
                    Toggle("English only", isOn: Binding(
                        get: { model.settings.languages == ["en"] },
                        set: { model.settings.languages = $0 ? ["en"] : [] }))
                    TextField("Languages, e.g. en, fr (empty for any)", text: Binding(
                        get: { model.settings.languages.joined(separator: ", ") },
                        set: { model.settings.languages = splitList($0) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Content")
                } footer: {
                    Text("English only is the same as typing en below. A paper whose language the source does not state is kept, because most do not say and dropping them would empty the feed.")
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
                    Text("Make the file in iCloud Drive on one device, then on each other device join that same file. Follows, mutes, keywords, sliders, saved and hidden papers and what you have read are shared and merged, so nothing is lost if you change things on two devices. The OpenAlex and Zotero keys and the feed itself stay on each device.")
                }

                Section {
                    Button("Save a backup of my settings…") { creatingBackup = true }
                    Button("Restore settings from a backup…") { restoringBackup = true }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("A file you keep: your follows, mutes, keywords, sliders, and saved and hidden papers as they are now. It does not hold your OpenAlex or Zotero key, the feed, or what you have read. Restoring replaces your current settings after asking, and with syncing on the other devices follow. Sync keeps your devices the same; a backup is how you go back.")
                }

                SummariesSection()

                ZoteroSection()

                LibraryFileSection()

                ProjectSection()

                PDFStorageSection()

                WatchedFolderSection()

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
        // On the stack, not the form: a view takes one exporter and one importer, and the sync
        // file's are on the form.
        .fileExporter(isPresented: $creatingBackup,
                      document: SyncFileDocument(data: creatingBackup ? model.backupData() : Data()),
                      contentType: .json, defaultFilename: Backup.filename(at: Date())) { _ in }
        .fileImporter(isPresented: $restoringBackup, allowedContentTypes: [.json]) { result in
            readBackup(result)
        }
        .confirmationDialog("Replace your settings with this backup?", isPresented: Binding(
            get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
            Button("Replace my settings", role: .destructive) {
                if let restored = pendingRestore { model.restore(restored.settings) }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            if let pending = pendingRestore {
                let when = pending.savedAt.map { "Saved " + $0.formatted(date: .abbreviated, time: .omitted) + ". " } ?? ""
                let what = pending.lines.isEmpty ? "It holds only default settings." : "It holds " + pending.lines.joined(separator: ", ") + "."
                Text(when + what + " Your current follows, mutes, keywords and sliders, and your saved and hidden papers, are replaced.")
            }
        }
        .alert("Could not restore", isPresented: Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(restoreError ?? "") }
    }

    private struct PendingRestore {
        let settings: FeedSettings
        let savedAt: Date?
        let lines: [String]
    }

    /// Read the chosen file and ask before replacing anything.
    private func readBackup(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            restoreError = "That file could not be read."
            return
        }
        switch Backup.decode(data) {
        case .settings(let restored, let savedAt):
            pendingRestore = PendingRestore(settings: restored, savedAt: savedAt, lines: Backup.summary(of: restored))
        case .newerFormat:
            restoreError = "That backup was made by a newer version of Scrollar. Update the app, then try again."
        case .notABackup:
            restoreError = "That is not a Scrollar settings backup. The sync file and other files cannot be restored this way."
        }
    }

    private func entityLink(_ title: String, kind: OpenAlexClient.EntityKind, items: Binding<[Entity]>,
                            byName: Bool = false, seedFor: ((Entity) -> Seed?)? = nil, explanation: String? = nil) -> some View {
        NavigationLink {
            EntityListView(title: title, kind: kind, items: items, byName: byName, seedFor: seedFor, explanation: explanation)
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
    /// The search each entry stands for, so a tap shows what it finds. nil for a list of mutes.
    var seedFor: ((Entity) -> Seed?)?
    /// What this list does to the feed, in plain words, under the list.
    var explanation: String?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("Nothing yet. Tap Add to search.").foregroundStyle(.secondary)
                }
                ForEach(items, id: \.id) { item in
                    if let seed = seedFor?(item) {
                        NavigationLink { SeedPreviewView(title: item.name, seed: seed) } label: { Text(item.name) }
                    } else {
                        Text(item.name)
                    }
                }
                .onDelete { items.remove(atOffsets: $0) }
            } footer: {
                if let explanation {
                    Text(explanation + (seedFor == nil ? "" : " Tap one to see the papers it finds."))
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) {
            EntitySearchSheet(kind: kind, title: title, byName: byName, seedFor: seedFor, chosen: items) { entity in
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
    var seedFor: ((Entity) -> Seed?)?
    let chosen: [Entity]
    let pick: (Entity) -> Void

    @State private var query = ""
    @State private var results: [OpenAlexClient.EntityHit] = []
    @State private var failure: String?
    @State private var added: Set<String> = []
    @State private var previewing: PreviewTarget?

    private struct PreviewTarget: Hashable { let title: String; let seed: Seed }

    /// The eye beside a result: see what following it would bring before following it.
    @ViewBuilder private func previewButton(_ entity: Entity) -> some View {
        if let seed = seedFor?(entity) {
            Button { previewing = PreviewTarget(title: entity.name, seed: seed) } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview the papers it finds")
        }
    }

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
                    HStack {
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        previewButton(Entity(id: id, name: trimmedQuery))
                    }
                }
                ForEach(results) { hit in
                    let done = added.contains(hit.id) || chosen.contains(hit.entity)
                    HStack {
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    previewButton(hit.entity)
                    }
                }
            }
            .navigationDestination(item: $previewing) { SeedPreviewView(title: $0.title, seed: $0.seed) }
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
            Section {
                if rules.isEmpty {
                    Text("Nothing yet. A phrase is searched in titles and abstracts.").foregroundStyle(.secondary)
                }
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    NavigationLink {
                        KeywordRuleEditor(rule: $rules[index])
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.phrase)
                            if !detail(rule).isEmpty {
                                Text(detail(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { rules.remove(atOffsets: $0) }
            } footer: {
                Text("Each phrase is searched in titles and abstracts, and everything it finds is kept in your feed, however low it would score. Importance ranks your keywords against each other: a High keyword lifts its papers up the list, a Low one lowers them. Open a keyword to set it, and to require or exclude other words. Add the same phrase again to follow it with different words: \"pain\" requiring EEG and \"pain\" requiring MRI are two rules, and a paper needs to pass only one of them.")
            }
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
                // The same phrase may be added again: each rule has its own words to require.
                if !phrase.isEmpty {
                    let taken = Set(rules.map(\.id))
                    rules.append(KeywordRule(phrase: phrase, id: taken.contains(phrase) ? UUID().uuidString : phrase))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func detail(_ rule: KeywordRule) -> String {
        var parts: [String] = []
        if rule.importance != .normal { parts.append("\(rule.importance.title) importance") }
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
                Picker("Importance", selection: $rule.importance) {
                    ForEach(Importance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Importance")
            } footer: {
                Text("High lifts the papers this keyword finds up the list; Low lowers them. A paper that a journal or researcher you follow also found is never ranked below Normal.")
            }
            Section {
                TextField("e.g. EEG, humans", text: Binding(
                    get: { rule.alsoRequire.joined(separator: ", ") },
                    set: { rule.alsoRequire = splitList($0) }))
            } header: {
                Text("Must also contain")
            } footer: {
                Text("Separate with commas. Every one must appear in the title or abstract, and they are also put to the sources, so a broad phrase finds papers that have them. To accept either of two words, add the phrase twice.")
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
            if !rule.phrase.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    NavigationLink("Preview the papers it finds") {
                        SeedPreviewView(title: rule.phrase, seed: rule.seed, rule: rule)
                    }
                } footer: {
                    Text("Try it before you decide: the newest papers this keyword, with its words, would put in your feed.")
                }
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

// MARK: - Preview of what a follow finds

/// The newest papers a follow would put in the feed, asked for now and not stored, so the
/// reader can judge a keyword as broad as "pain", or a journal, before keeping it.
struct SeedPreviewView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let seed: Seed
    var rule: KeywordRule?

    private enum Load {
        case loading
        case loaded(SeedPreview)
        case failed(String)
    }
    @State private var load = Load.loading

    /// A topic, an institution or a funder is ranked with the rest, not listed in full.
    private var isBroad: Bool { Paper.broadReasonPrefixes.contains { seed.reason.hasPrefix($0) } }

    var body: some View {
        List {
            switch load {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking the sources…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
                Button("Try again") { Task { await run() } }
            case .loaded(let preview):
                Section {
                    Text(summary(preview))
                    if preview.removed > 0 {
                        Text("\(preview.removed) more \(preview.removed == 1 ? "was" : "were") removed by this keyword's own words, your mutes or your filters.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !preview.papers.isEmpty {
                    Section {
                        ForEach(preview.papers, id: \.dedupeKey) { PreviewRow(paper: $0) }
                    } footer: {
                        Text(preview.matched > preview.papers.count
                             ? "The newest \(preview.papers.count) of \(preview.matched)\(preview.mayHaveMore ? " or more" : "")."
                             : "Newest first.")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: seed) { await run() }
    }

    private func summary(_ p: SeedPreview) -> String {
        let days = model.settings.daysBack
        if p.matched == 0 { return "Nothing in the last \(days) days." }
        let count = "\(p.matched)\(p.mayHaveMore ? " or more" : "") \(p.matched == 1 ? "paper" : "papers")"
        return isBroad
            ? "\(count) in the last \(days) days. It is broad, so they are ranked with everything else and the best reach your feed, with a small bonus."
            : "\(count) in the last \(days) days, all of which would be in your feed, however low they score."
    }

    private func run() async {
        load = .loading
        do { load = .loaded(try await model.preview(seed, rule: rule)) }
        catch is CancellationError {}
        catch { load = .failed("\(error)") }
    }
}

private struct PreviewRow: View {
    let paper: Paper

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text(paper.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text([paper.journal, paper.date].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        if let url = paper.link {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}


/// Connecting a Zotero library: its newest items stand for what the user is into now, like the
/// papers they save. The key is checked with Zotero, kept in the Keychain and sent only there.
struct ZoteroSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var key = ""
    @State private var connecting = false
    @State private var problem: String?
    @State private var collections: [Zotero.Collection] = []
    @State private var collectionNote: String?

    private func loadCollections() async {
        guard let account = appModel.zotero, account.canWrite else { return }
        do { collections = try await ZoteroClient(account: account).collections(); collectionNote = nil }
        catch { collectionNote = "The collections could not be listed: \(error)" }
    }

    private func createCollection() async {
        guard let account = appModel.zotero else { return }
        do {
            let made = try await ZoteroClient(account: account).createCollection(named: "Scrollar")
            collections = (collections + [made]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            appModel.zoteroCollection = made
        } catch { collectionNote = "\(error)" }
    }

    var body: some View {
        @Bindable var model = appModel
        Section {
            if let account = model.zotero {
                LabeledContent("Connected as", value: account.username.isEmpty ? "user \(account.userID)" : account.username)
                Text(account.canWrite ? "This key can read your library and save papers to it."
                                      : "This key can only read your library. Saving papers to it needs a key that may also write.")
                    .font(.footnote).foregroundStyle(.secondary)
                if account.canWrite {
                    Picker("Save papers into", selection: Binding(
                        get: { model.zoteroCollection?.key ?? "" },
                        set: { key in model.zoteroCollection = collections.first { $0.key == key } })) {
                        Text("My Library (no collection)").tag("")
                        // The chosen one stays listed while the list loads, or if it was renamed.
                        if let chosen = model.zoteroCollection, !collections.contains(chosen) {
                            Text(chosen.name).tag(chosen.key)
                        }
                        ForEach(collections, id: \.key) { Text($0.name).tag($0.key) }
                    }
                    if !collections.contains(where: { $0.name == "Scrollar" }) {
                        Button("Create a “Scrollar” collection and use it") { Task { await createCollection() } }
                    }
                    Toggle("Attach the PDF when one is free to read", isOn: $model.zoteroAttachPDF)
                    if let note = collectionNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
                Toggle("Learn from my library", isOn: $model.settings.useZotero)
                if model.settings.useZotero {
                    Stepper("Newest items used: \(model.settings.zoteroRecent)",
                            value: $model.settings.zoteroRecent, in: 10...500, step: 10)
                    if let status = model.zoteroStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Disconnect", role: .destructive) { model.zoteroCollection = nil; model.disconnectZotero() }
            } else {
                SecureField("Zotero API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(connecting ? "Connecting…" : "Connect") { connect() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                Link("Create a key at zotero.org", destination: URL(string: "https://www.zotero.org/settings/keys/new")!)
            }
        } header: {
            Text("Zotero library")
        } footer: {
            Text("Your most recently added items (title, abstract and tags) are read and compared on this device, as your saved papers are, to judge which new papers are close to your work. Only the newest ones count, so what you are reading now outweighs what you filed years ago. Nothing is followed because of it: Follow lists stay yours. The key stays in this device's Keychain and is sent only to Zotero. A read-only key is enough to learn from the library; to also save papers from a post it must be allowed to write. A PDF attached to an item is stored in your Zotero file storage and counts against its quota (300 MB on the free plan); if it is full the paper is still saved, without the PDF.")
        }
        .task(id: model.zotero?.userID) { await loadCollections() }
    }

    private func connect() {
        connecting = true
        problem = nil
        Task {
            do {
                try await appModel.connectZotero(key: key)
                key = ""
            } catch {
                problem = "\(error)"
            }
            connecting = false
        }
    }
}


/// Takeaways on a device without an on-device model. Apple's is used wherever there is one; where
/// there is not (Apple Intelligence is not offered in every region), a Claude or ChatGPT account of
/// the user's own can write them, which sends the title and abstract of papers they scroll past.
struct SummariesSection: View {
    @Environment(AppModel.self) private var model
    @State private var provider = SummaryProvider.anthropic
    @State private var key = ""
    @State private var modelName = ""
    @State private var testing = false
    @State private var problem: String?

    var body: some View {
        Section {
            LabeledContent("Papers are compared with", value: model.embeddingDescription)
            if Summarizer.isAvailable {
                Label("This device writes them itself, with Apple's language model.", systemImage: "checkmark.circle")
            } else if let config = model.remoteSummary {
                LabeledContent("Written by", value: "\(config.provider.name), \(config.modelOrDefault)")
                if let problem = model.summaryProblem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                    Button("Try again") { model.clearSummaryProblem() }
                }
                Button("Stop using it", role: .destructive) { model.clearRemoteSummary() }
            } else {
                Text("This device has no on-device language model, so the sentence under each title is chosen from the abstract. Set up your own account to have a model write it.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Account", selection: $provider) {
                    ForEach(SummaryProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Model (blank: \(provider.defaultModel))", text: $modelName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "Trying it…" : "Try it and keep it") { setUp() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                Link(provider == .anthropic ? "Get a Claude API key" : "Get an OpenAI API key",
                     destination: URL(string: provider == .anthropic ? "https://console.anthropic.com/settings/keys"
                                                                     : "https://platform.openai.com/api-keys")!)
            }
        } header: {
            Text("Summaries and matching")
        } footer: {
            Text("Matching uses a text model on this device: Apple's sentence model where it has one, otherwise its contextual model, which is fetched once and does not need Apple Intelligence; with neither, words alone. A key is not a chat subscription: it is a separate, pay-per-use account of your own (Claude or OpenAI). When it is set up, the title and abstract of a paper that stays on screen are sent to that service, and nothing else. Each takeaway costs a fraction of a cent to a cent or two, depending on the model: a smaller one costs far less, and Claude Haiku (claude-haiku-5-5) is the cheapest Claude. At most \(Summarizer.remoteLimit) are written per launch, and each is kept, so a paper is never asked for twice. The key stays in this device's Keychain and is sent only to that service. A device that has Apple's model uses it instead and sends nothing.")
        }
    }

    private func setUp() {
        testing = true
        problem = nil
        let config = RemoteSummaryConfig(provider: provider, key: key.trimmingCharacters(in: .whitespacesAndNewlines), model: modelName)
        Task {
            do {
                try await model.setUpRemoteSummary(config)
                key = ""
            } catch {
                problem = "\(error)"
            }
            testing = false
        }
    }
}


/// EndNote, Mendeley, Papers, Citavi and the rest have no way in that an app can use, but every one
/// exports RIS or BibTeX. Importing one gives the same signal as Zotero's library does.
struct LibraryFileSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var choosing = false
    @State private var pasting = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        @Bindable var model = appModel
        Section {
            if let file = model.libraryFile {
                LabeledContent("Imported", value: "\(file.items.count) papers")
                Text("From \(file.name), \(importedText(file.importedAt)).").font(.footnote).foregroundStyle(.secondary)
                Toggle("Learn from it", isOn: $model.settings.useLibraryFile)
                if model.settings.useLibraryFile {
                    Stepper("Newest items used: \(model.settings.zoteroRecent)",
                            value: $model.settings.zoteroRecent, in: 10...500, step: 10)
                }
                importButton("Import a newer export…")
                Button("Paste more references…") { pasting = true }
                Button("Remove it", role: .destructive) { model.removeLibraryFile(); message = nil }
            } else {
                importButton("Import an export (RIS or BibTeX)…")
                Button("Paste references…") { pasting = true }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(failed ? Color.red : Color.secondary) }
        } header: {
            Text("Library file (EndNote, Mendeley and others)")
        } footer: {
            Text("The quickest way: choose Paste references, then copy from your reference manager (select papers, Copy, or Copy as reference list) or from any bibliography and paste. A RIS or BibTeX export pasted there is read as one; a plain list gives a title and DOI per reference, and a paper with only a DOI is left out. Or, in your reference manager, export your library (or the part you are working on) as RIS or BibTeX, then choose the file here. It is read on this device, and its titles, abstracts and keywords stand for what you are into, as a Zotero library does. An export does not say when each paper was added, so the first import treats them alike and puts the more recently published first; import a newer export from time to time and the papers that were not in the last one count as the newest. The file is not kept, only what was read from it, and it is not synced: import it on each device.")
        }
        .sheet(isPresented: $pasting) { PasteReferencesSheet { paste($0) } }
    }

    private func paste(_ text: String) {
        do {
            let r = try appModel.addPastedReferences(text)
            failed = false
            message = "Added \(r.added) papers; \(r.total) in all."
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }

    private func importButton(_ title: String) -> some View {
        Button(title) { choosing = true }
            .fileImporter(isPresented: $choosing,
                          allowedContentTypes: [UTType(filenameExtension: "ris"), UTType(filenameExtension: "bib"),
                                                UTType(filenameExtension: "bibtex"), .plainText, .text].compactMap { $0 }) { result in
                switch result {
                case .success(let url):
                    do {
                        let r = try appModel.importLibrary(from: url)
                        failed = false
                        message = "Read \(r.total) papers" + (r.added == r.total ? "." : ", \(r.added) new since the last import.")
                    } catch {
                        failed = true
                        message = error.localizedDescription
                    }
                case .failure(let error):
                    failed = true
                    message = error.localizedDescription
                }
            }
    }

    private func importedText(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "imported" }
        return "imported " + d.formatted(date: .abbreviated, time: .omitted)
    }
}


/// A research project in the user's own words (a grant proposal, a thesis plan, an abstract): what the
/// feed is for, in the place of papers that do not exist yet. Read on the device and kept there.
struct ProjectSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var pasting = false
    @State private var suggesting = false
    @State private var message: String?

    var body: some View {
        Section {
            if let project = appModel.project {
                LabeledContent("Using", value: project.name)
                Text("\(ProjectText.wordCount(project.text)) words, \(ProjectText.passages(project.text).count) passages read, pasted \(pasted(project.addedAt)).")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Suggest keywords from it…") { suggesting = true }
                Button("Replace it…") { pasting = true }
                Button("Remove it", role: .destructive) { appModel.removeProject(); message = nil }
            } else {
                Button("Paste your project…") { pasting = true }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Your project")
        } footer: {
            Text("Paste a grant proposal, a thesis plan or an abstract: what you are about to work on, before there are papers to show it. Papers close to it rank higher, and it can suggest keywords to follow, which you choose from a list. It is read on this device and kept only here: it is not synced, not sent to any service, and not in the settings file you can export. Only a keyword you choose to follow is searched, like any other.")
        }
        .sheet(isPresented: $pasting) {
            PasteProjectSheet { text in
                do {
                    try appModel.setProject(text)
                    message = nil
                    // After this sheet has gone: a second one cannot open while it is leaving.
                    Task { try? await Task.sleep(for: .milliseconds(500)); suggesting = true }
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $suggesting) { ProjectKeywordsSheet() }
    }

    private func pasted(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "earlier" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A window to paste a project into, or to take one from a PDF or a text file.
struct PasteProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var choosing = false
    @State private var problem: String?
    let save: (String) -> Void

    private var words: Int { ProjectText.wordCount(text) }
    private var enough: Bool { words >= ProjectText.fewestWords && !ProjectText.passages(text).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste the description of your project: the aims and background of a grant proposal, a thesis plan or an abstract. The more of it that is about the subject, and the less about budgets and schedules, the better it works.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.callout)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .frame(minHeight: 220)
                HStack {
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        if let clip = UIPasteboard.general.string { text = clip }
                    }
                    Spacer()
                    Button("From a file…", systemImage: "doc") { choosing = true }
                }
                Text(problem ?? (text.isEmpty ? "" : enough ? "\(words) words" : "Too short to tell what it is about"))
                    .font(.footnote).foregroundStyle(problem != nil || !enough ? Color.red : Color.secondary)
            }
            .padding()
            .navigationTitle("Your project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use it") { save(text); dismiss() }.disabled(!enough)
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf, .plainText, .text]) { result in
                switch result {
                case .success(let url):
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let read = url.pathExtension.lowercased() == "pdf" ? PDFDocument(url: url)?.string : try? String(contentsOf: url)
                    if let read, !read.isEmpty { text = read; problem = nil } else { problem = "That file has no text that could be read." }
                case .failure(let error):
                    problem = error.localizedDescription
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// What the project keeps returning to, to choose from. Nothing is searched until it is added; the
/// phrases come from the text on this device, and are not sent anywhere before the choice.
struct ProjectKeywordsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var found: [ProjectKeyword] = []
    @State private var chosen: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && found.isEmpty {
                    ContentUnavailableView("No repeated phrases", systemImage: "text.magnifyingglass",
                                           description: Text("The project does not return to any phrase often enough to suggest it. Add keywords by hand under Follow."))
                } else {
                    Section {
                        Text("Phrases the project returns to, most often first. A keyword is searched in titles and abstracts and listed in full, so a broad one lists a great deal: leave out what is too general. You can narrow one afterwards, under Follow, Keywords.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Phrases") { ForEach(found.filter { $0.words > 1 }) { row($0) } }
                    let singles = found.filter { $0.words == 1 }
                    if !singles.isEmpty {
                        Section {
                            ForEach(singles) { row($0) }
                        } header: {
                            Text("Single words")
                        } footer: {
                            Text("A word on its own is searched everywhere it appears, so none is ticked.")
                        }
                    }
                }
            }
            .navigationTitle("Suggested keywords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(chosen.count)") {
                        model.followKeywords(found.filter { chosen.contains($0.id) }.map(\.phrase))
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .task {
                let text = model.project?.text ?? ""
                found = ProjectText.keywords(text).filter { k in
                    !model.settings.followedKeywords.contains { $0.phrase.lowercased() == k.id }
                }
                chosen = Set(found.filter(\.selected).map(\.id))
                loaded = true
            }
        }
    }

    private func row(_ k: ProjectKeyword) -> some View {
        Button {
            if chosen.contains(k.id) { chosen.remove(k.id) } else { chosen.insert(k.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: chosen.contains(k.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen.contains(k.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.phrase).foregroundStyle(.primary)
                    Text("\(k.count) times").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A window to paste into: anything a reference manager or a bibliography will copy.
struct PasteReferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let add: (String) -> Void

    private var found: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : LibraryImport.rough(text).count }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste references from your reference manager, a bibliography or a list of titles, one per entry. RIS and BibTeX work too.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.callout)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .frame(minHeight: 220)
                HStack {
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        if let clip = UIPasteboard.general.string { text = clip }
                    }
                    Spacer()
                    Text(text.isEmpty ? "" : found == 0 ? "Nothing readable yet" : "\(found) papers found")
                        .font(.footnote).foregroundStyle(found == 0 ? .red : .secondary)
                }
            }
            .padding()
            .navigationTitle("Paste references")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(text); dismiss() }.disabled(found == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The PDFs kept for the reader: how much room they take, a cap, a way to empty them, and an
/// optional folder (in iCloud Drive) that shares them between devices.
struct PDFStorageSection: View {
    @State private var usage = PDFCache.usage()
    @State private var limit: Int? = PDFCache.limit
    @State private var clearing = false
    @State private var folder: URL? = PDFFolder.url
    @State private var folderUsage = PDFFolder.usage()
    @State private var policy = PDFFolder.policy
    @State private var choosing = false

    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    var body: some View {
        Section {
            LabeledContent("Kept on this device",
                           value: usage.count == 0 ? "Nothing" : "\(size(usage.bytes)) in \(usage.count) PDF" + (usage.count == 1 ? "" : "s"))
            Picker("Keep up to", selection: $limit) {
                ForEach(PDFCachePlan.limits, id: \.label) { Text($0.label).tag($0.bytes) }
            }
            .onChange(of: limit) { PDFCache.limit = limit; PDFCache.trim(); usage = PDFCache.usage() }
            Button("Clear downloaded PDFs…", role: .destructive) { clearing = true }
                .disabled(usage.count == 0)
        } header: {
            Text("Downloaded PDFs")
        } footer: {
            Text("A PDF opened in the reader is kept here, so it opens again at once, without a connection, and can be sent to a reference manager. When the limit is passed the ones you used longest ago are deleted first, and those of papers you saved or marked For me last. The system may also empty this space when the device is short of it. Nothing here is part of your settings or sync.")
        }

        Section {
            if let folder {
                LabeledContent("Folder", value: folder.lastPathComponent)
                LabeledContent("Holds", value: folderUsage.count == 0 ? "Nothing yet" : "\(size(folderUsage.bytes)) in \(folderUsage.count) PDF" + (folderUsage.count == 1 ? "" : "s"))
                Picker("Put in it", selection: $policy) {
                    Text("Saved and For me papers").tag(PDFFolder.Policy.saved)
                    Text("Every PDF I open").tag(PDFFolder.Policy.everything)
                }
                .onChange(of: policy) { PDFFolder.policy = policy }
                Button("Choose another folder…") { choosing = true }
                Button("Stop using this folder", role: .destructive) { PDFFolder.forget(); self.folder = nil }
            } else {
                Button("Choose a folder in iCloud Drive…") { choosing = true }
            }
        } header: {
            Text("Share PDFs between devices")
        } footer: {
            Text("Choose the same folder in iCloud Drive on each device. A PDF opened or saved on one is then there on the others, which look in the folder before downloading. The files are named after the paper, so you can find them in Files. Nothing here trims the folder or deletes from it, and it counts against your iCloud storage: delete files there when you want the room. Stopping only makes this device forget the folder.")
        }
        .onAppear { usage = PDFCache.usage(); folderUsage = PDFFolder.usage() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, PDFFolder.adopt(url) {
                folder = PDFFolder.url
                folderUsage = PDFFolder.usage()
            }
        }
        .confirmationDialog("Delete the downloaded PDFs?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { PDFCache.clear(keepingSaved: false); usage = PDFCache.usage() }
            Button("Delete all except saved papers", role: .destructive) { PDFCache.clear(keepingSaved: true); usage = PDFCache.usage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can be downloaded again from the paper. PDFs in the shared folder are not touched.")
        }
    }
}

/// A folder a reference manager imports PDFs from by itself.
struct WatchedFolderSection: View {
    @State private var folder: URL? = WatchedFolder.url
    @State private var choosing = false

    var body: some View {
        Section {
            if let folder {
                LabeledContent("Folder", value: folder.lastPathComponent)
                Button("Choose another folder…") { choosing = true }
                Button("Stop using this folder", role: .destructive) { WatchedFolder.forget(); self.folder = nil }
            } else {
                Button("Choose the folder…") { choosing = true }
            }
        } header: {
            Text("Reference manager folder")
        } footer: {
            Text("EndNote can import PDFs from a folder by itself (its Settings, PDF Handling, Enable automatic importing; it looks when it opens, and moves what it imported into an Import subfolder), and Mendeley can watch one. Choose that folder here and a paper's Share menu gets Put the PDF in it. The manager reads the paper's details from the PDF, so a paper without a DOI may arrive without them; for those the .enw or .ris file is better. Zotero has no such folder: use Save to Zotero.")
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, WatchedFolder.adopt(url) { folder = WatchedFolder.url }
        }
    }
}
