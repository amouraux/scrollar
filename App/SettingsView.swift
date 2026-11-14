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

/// The screens Tune opens on, so that something outside Tune can take the user straight to one.
enum TuneScreen: String, Hashable, CaseIterable {
    case you, follow, ranking, content, references, pdfs, summaries, sources, sync

    var title: String {
        switch self {
        case .you: return "You"
        case .follow: return "Follow and mute"
        case .ranking: return "Ranking"
        case .content: return "Content and display"
        case .references: return "Reference managers"
        case .pdfs: return "PDFs"
        case .summaries: return "Summaries and AI"
        case .sources: return "Sources"
        case .sync: return "Sync and backup"
        }
    }

    var symbol: String {
        switch self {
        case .you: return "person.crop.circle"
        case .follow: return "binoculars"
        case .ranking: return "arrow.up.arrow.down"
        case .content: return "text.alignleft"
        case .references: return "books.vertical"
        case .pdfs: return "doc.richtext"
        case .summaries: return "sparkles"
        case .sources: return "network"
        case .sync: return "icloud"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var path: [TuneScreen] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    row(.you, status: youStatus)
                    row(.follow, status: followStatus)
                    row(.ranking, status: rankingStatus)
                    row(.content, status: contentStatus)
                } header: {
                    Text("Your feed")
                } footer: {
                    Text("What you follow decides what is searched for. Your publications, projects and reference library decide only the order: they can suggest what to follow, but nothing is followed until you add it. Changes take effect when you go back to the feed.")
                }
                Section("Connections and data") {
                    row(.references, status: referencesStatus)
                    row(.pdfs, status: pdfsStatus)
                    row(.summaries, status: summariesStatus)
                    row(.sources, status: sourcesStatus)
                    row(.sync, status: appModel.syncStatusText)
                }
            }
            .navigationTitle("Tune")
            .navigationDestination(for: TuneScreen.self) { screen in
                switch screen {
                case .you: YouScreen()
                case .follow: FollowScreen()
                case .ranking: RankingScreen()
                case .content: ContentScreen()
                case .references: ReferencesScreen()
                case .pdfs: PDFsScreen()
                case .summaries: SummariesScreen()
                case .sources: SourcesScreen()
                case .sync: SyncBackupScreen()
                }
            }
        }
        // Asked for from the feed's first-run list; the tab may only just have appeared, so it is
        // also looked at when it does.
        .onChange(of: appModel.pendingTune) { _, _ in openPending() }
        .onAppear { openPending() }
    }

    private func openPending() {
        guard let screen = appModel.pendingTune else { return }
        appModel.pendingTune = nil
        path = [screen]
    }

    private func row(_ screen: TuneScreen, status: String) -> some View {
        NavigationLink(value: screen) {
            LabeledContent {
                Text(status).lineLimit(1)
            } label: {
                Label(screen.title, systemImage: screen.symbol)
            }
        }
    }

    // What each row says about the screen behind it, so most of the time there is no need to open it.

    private var youStatus: String {
        let s = appModel.settings
        var parts: [String] = []
        if let orcid = s.orcid, Orcid.normalised(orcid) != nil { parts.append("ORCID") }
        if !appModel.projects.isEmpty { parts.append(appModel.projects.count == 1 ? "project" : "\(appModel.projects.count) projects") }
        if !s.profileOrcids.isEmpty { parts.append("+\(s.profileOrcids.count) learned from") }
        return parts.isEmpty ? "Not set up" : parts.joined(separator: " · ")
    }

    private var followStatus: String {
        let s = appModel.settings
        let follows = s.followedTopics.count + s.followedJournals.count + s.followedAuthors.count
            + s.followedInstitutions.count + s.followedFunders.count + s.followedKeywords.count
        let mutes = s.mutedJournals.count + s.mutedAuthors.count + s.mutedTopics.count + s.mutedKeywords.count
        return "\(follows) followed" + (mutes == 0 ? "" : " · \(mutes) muted")
    }

    private var rankingStatus: String {
        let s = appModel.settings
        return s.highlightCount == 0 ? "No highlights" : "\(s.highlightCount) highlights"
    }

    private var contentStatus: String {
        let s = appModel.settings
        var parts: [String] = []
        if s.requireAbstract { parts.append("abstract") }
        if s.openAccessOnly { parts.append("open access") }
        if !s.languages.isEmpty { parts.append(s.languages.joined(separator: ", ")) }
        return parts.isEmpty ? "No filters" : "Only " + parts.joined(separator: ", ")
    }

    private var referencesStatus: String {
        let chosen = appModel.settings.referenceManagers
        if !chosen.isEmpty { return chosen.map(\.title).joined(separator: ", ") }
        var parts: [String] = []
        if appModel.zotero != nil { parts.append("Zotero") }
        if appModel.libraryFile != nil { parts.append("reference export") }
        return parts.isEmpty ? "Not chosen" : parts.joined(separator: " · ")
    }

    private var pdfsStatus: String {
        let used = PDFCache.usage()
        let kept = used.count == 0 ? "None kept" : ByteCountFormatter.string(fromByteCount: Int64(used.bytes), countStyle: .file)
        return PDFFolder.url == nil ? kept : kept + " · shared"
    }

    private var summariesStatus: String {
        let account = appModel.remoteSummary?.displayName
        if Summarizer.isAvailable { return account.map { "Apple's model, \($0)" } ?? "Apple's model" }
        return account ?? "None"
    }

    private var sourcesStatus: String {
        let s = appModel.settings
        let openAlex = s.useOpenAlex ? (appModel.hasKey ? "OpenAlex" : "OpenAlex (no key)") : nil
        let on = [s.useEuropePMC ? "Europe PMC" : nil, openAlex,
                  s.useCrossref ? "Crossref" : nil, s.useArXiv ? "arXiv" : nil, s.useOSF ? "OSF" : nil].compactMap { $0 }
        return on.isEmpty ? "None on" : on.joined(separator: ", ")
    }
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
                    failure = model.hasKey ? "Search failed: \(ErrorText.brief(error))" : "Add your OpenAlex key first."
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
        catch { load = .failed("\(ErrorText.brief(error))") }
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
        catch { collectionNote = "The collections could not be listed: \(ErrorText.brief(error))" }
    }

    private func createCollection() async {
        guard let account = appModel.zotero else { return }
        do {
            let made = try await ZoteroClient(account: account).createCollection(named: "Scrollar")
            collections = (collections + [made]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            appModel.zoteroCollection = made
        } catch { collectionNote = "\(ErrorText.brief(error))" }
    }

    var body: some View {
        @Bindable var model = appModel
        Section {
            if let account = model.zotero {
                LabeledContent("Key", value: SecretText.masked(account.key))
                LabeledContent("Connected as", value: account.username.isEmpty ? "user \(account.userID)" : account.username)
                // What the app was told when it was asked, not just what it kept: a stored key proves nothing.
                if let check = model.zoteroCheck {
                    Label(check.text, systemImage: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.footnote).foregroundStyle(check.ok ? Color.green : Color.red)
                } else {
                    Label("Key stored on this device. Not checked since the app opened.", systemImage: "questionmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(model.zoteroChecking ? "Checking…" : "Check the connection") { Task { await model.checkZotero() } }
                    .disabled(model.zoteroChecking)
                if account.canWrite {
                    Text("This key can read your library and add papers to it.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("This key can only read your library. Adding papers to it needs a key that may also write.")
                        .font(.footnote).foregroundStyle(.secondary)
                    SetupPageRows(page: SetupHelp.zoteroKeys)
                }
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
                Label("No key stored: not connected.", systemImage: "link.badge.plus")
                    .font(.footnote).foregroundStyle(.secondary)
                SetupPageRows(page: SetupHelp.zotero(needsWrite: false))
                SecureField("Zotero API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(connecting ? "Connecting…" : "Connect") { connect() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
        } header: {
            Text("Zotero library")
        } footer: {
            Text("Your most recently added items (title, abstract and tags) are read and compared on this device, as your reading list is, to judge which new papers are close to your work. Only the newest ones count, so what you are reading now outweighs what you filed years ago. It changes only the order: nothing is searched for or followed because of it. The key stays in this device's Keychain and is sent only to Zotero. A read-only key is enough to learn from the library; to also save papers from a post it must be allowed to write. A PDF attached to an item is stored in your Zotero file storage and counts against its quota (300 MB on the free plan); if it is full the paper is still saved, without the PDF.")
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
                problem = "\(ErrorText.brief(error))"
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
    @State private var endpoint = ""
    @State private var testing = false
    @State private var problem: String?

    private var canSetUp: Bool {
        if testing { return false }
        if provider == .other {
            return RemoteSummary.endpoint(endpoint) != nil && !modelName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Section {
            LabeledContent("Papers are compared with", value: model.embeddingDescription)
            if Summarizer.isAvailable {
                Label("This device writes the takeaways itself, with Apple's language model.", systemImage: "checkmark.circle")
            }
            if let config = model.remoteSummary {
                LabeledContent(Summarizer.isAvailable ? "Another model" : "Written by", value: "\(config.displayName), \(config.modelOrDefault)")
                if let problem = model.summaryProblem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                    Button("Try again") { model.clearSummaryProblem() }
                }
                Button("Stop using it", role: .destructive) { model.clearRemoteSummary() }
            } else {
                Text(Summarizer.isAvailable
                     ? "Optional: set up an account of your own, with Claude, ChatGPT or another model. It does not write the takeaways here, because this device does; it is offered, on request, for suggesting keywords from a project, with a warning that shows what is sent."
                     : "This device has no on-device language model, so the sentence under each title is chosen from the abstract. Set up your own account to have a model write it, and to suggest keywords from a project on request.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Account", selection: $provider) {
                    ForEach(SummaryProvider.allCases, id: \.self) { Text($0.pickerTitle).tag($0) }
                }
                if provider == .other {
                    TextField("Address, e.g. https://api.mistral.ai/v1", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                SecureField(provider == .other ? "API key (blank for a model on your own machine)" : "API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(provider.defaultModel.isEmpty ? "Model name" : "Model (blank: \(provider.defaultModel))", text: $modelName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(testing ? "Trying it…" : "Try it and keep it") { setUp() }
                    .disabled(!canSetUp)
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                if let page = SetupHelp.summaries(provider) { SetupPageRows(page: page) }
            }
        } header: {
            Text("Summaries and matching")
        } footer: {
            Text("Matching uses a text model on this device: Apple's sentence model where it has one, otherwise its contextual model, which is fetched once and does not need Apple Intelligence; with neither, words alone. A key is not a chat subscription: it is a separate, pay-per-use account of your own (Claude or OpenAI), or one from any service that speaks OpenAI's chat format (Mistral, Gemini's compatible address, OpenRouter, or a model on your own machine, such as Ollama, at an http:// address on this device or your network). A subscription to a chat app cannot be used. When an account is set up and this device has no model of its own, the title and abstract of a paper that stays on screen are sent to that service, and nothing else, except that you can also ask it to suggest keywords from a project you pasted (under Your project): then an excerpt of the project is sent, after a warning that shows exactly what goes and to whom, each time you ask. Each takeaway costs a fraction of a cent to a cent or two, depending on the model: a smaller one costs far less, and Claude Haiku (claude-haiku-5-5) is the cheapest Claude. At most \(Summarizer.remoteLimit) are written per launch, and each is kept, so a paper is never asked for twice. The key stays in this device's Keychain and is sent only to that service. A device that has Apple's model writes the takeaways itself and sends nothing for them.")
        }
    }

    private func setUp() {
        testing = true
        problem = nil
        let config = RemoteSummaryConfig(provider: provider, key: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                         model: modelName, endpoint: provider == .other ? endpoint : "")
        Task {
            do {
                try await model.setUpRemoteSummary(config)
                key = ""
            } catch {
                problem = "\(ErrorText.brief(error))"
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
                importButton("Replace with a newer export…")
                Button("Add references by pasting…") { pasting = true }
                Button("Remove it", role: .destructive) { model.removeLibraryFile(); message = nil }
            } else {
                Label("Nothing imported.", systemImage: "tray")
                    .font(.footnote).foregroundStyle(.secondary)
                if model.zotero != nil {
                    Text("Zotero is connected, which already reads your newest items. An export is only for a manager with no connection of its own.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                importButton("Import an export (RIS or BibTeX)…")
                Button("Paste references…") { pasting = true }
            }
            if let message { Text(message).font(.footnote).foregroundStyle(failed ? Color.red : Color.secondary) }
        } header: {
            Text("Reference export (EndNote, Mendeley and others)")
        } footer: {
            Text("For a manager that has no connection of its own: EndNote, Mendeley, Papers, Citavi. Like a Zotero library, what you import changes only the order of the feed: papers close to it rank higher, and nothing is searched for or followed because of it. Paste references: copy from your manager (select papers, Copy, or Copy as reference list) or from any bibliography, and paste; an export in RIS or BibTeX pasted works too. Or export your library as RIS or BibTeX and choose the file. Replace with a newer export takes the new file as your whole library: papers no longer in it are dropped, those already here keep the date they first appeared, and the others count as the newest. Add references by pasting only adds, and drops nothing; a paper pasted twice is one. What was read, not the file, is kept on this device and is not synced: do it on each device. If you use Zotero, connect it instead.")
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
    @State private var adding = false
    @State private var suggestingFor: ProjectRef?
    @State private var message: String?

    struct ProjectRef: Identifiable { let id: String }

    var body: some View {
        Section {
            ForEach(appModel.projects) { project in
                NavigationLink {
                    ProjectScreen(id: project.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                        Text("\(ProjectText.wordCount(project.text)) words · \(project.enabled ? "ranks the feed" : "not in use")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button(appModel.projects.isEmpty ? "Paste your project…" : "Add a project…") { adding = true }
                .disabled(appModel.projects.count >= ProjectText.maxProjects)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Your projects")
        } footer: {
            Text("Paste a grant proposal, a thesis plan or an abstract: what you are about to work on, before there are papers to show it. A project changes only the order: papers close to it rank higher, and nothing is searched for because of it. To search for what it is about, open it, choose Suggest keywords from it, and follow the ones you want. A project is read on this device and kept only here: it is not synced and not in the settings file you can export. It is sent to no service unless you ask a model you set up (Claude, ChatGPT or another), with your own account, to suggest keywords, and then only after a warning that shows exactly what goes. Apple's on-device model, where the device has one, reads it without sending anything.")
        }
        .sheet(isPresented: $adding) {
            PasteProjectSheet(replacing: false) { title, text in
                do {
                    let id = try appModel.addProject(title: title, text: text)
                    message = nil
                    // After this sheet has gone: a second one cannot open while it is leaving.
                    Task { try? await Task.sleep(for: .milliseconds(500)); suggestingFor = ProjectRef(id: id) }
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .sheet(item: $suggestingFor) { ProjectKeywordsSheet(projectID: $0.id) }
    }
}

/// One project: its title, whether it ranks the feed, its text, and what can be done with it.
struct ProjectScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var title = ""
    @State private var replacing = false
    @State private var suggesting = false
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        if let project = model.project(id: id) {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .onSubmit { model.renameProject(id: id, to: title) }
                    Toggle("Use it to rank the feed", isOn: Binding(
                        get: { project.enabled }, set: { model.setProjectEnabled($0, id: id) }))
                } footer: {
                    Text("Papers close to a project that is in use rank higher. The text decides how close a paper is; it does not fetch anything. Following keywords from it, with Suggest keywords from it below, is what makes it search.")
                }

                Section {
                    LabeledContent("Text", value: "\(ProjectText.wordCount(project.text)) words, \(passages(project.text))")
                    LabeledContent("Pasted", value: pasted(project.addedAt))
                    DisclosureGroup("Show the text") {
                        Text(String(project.text.prefix(4000))).font(.footnote).textSelection(.enabled)
                    }
                    Button("Suggest keywords from it…") { suggesting = true }
                    Button("Replace the text…") { replacing = true }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text("Replacing the text discards the old text for the new, and does not merge them. The title, and any keywords you already follow, stay.")
                }

                Section {
                    Button("Delete this project", role: .destructive) { deleting = true }
                } footer: {
                    Text("Keywords you followed from it stay followed, under Follow and mute.")
                }
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { title = project.name }
            .onDisappear { model.renameProject(id: id, to: title) }
            .sheet(isPresented: $replacing) {
                PasteProjectSheet(replacing: true) { _, text in
                    do { try model.replaceProjectText(id: id, with: text); message = nil }
                    catch { message = error.localizedDescription }
                }
            }
            .sheet(isPresented: $suggesting) { ProjectKeywordsSheet(projectID: id) }
            .confirmationDialog("Delete “\(project.name)”?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.removeProject(id: id); dismiss() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("This project is gone", systemImage: "doc")
        }
    }

    private func passages(_ text: String) -> String {
        let n = ProjectText.passages(text).count
        return n == 1 ? "1 passage" : "\(n) passages"
    }

    private func pasted(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "earlier" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A window to paste a project into, or to take one from a PDF or a text file. A new one has a title,
/// suggested from the text when its first line reads as one; replacing a text leaves the title alone.
struct PasteProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let replacing: Bool
    let save: (String, String) -> Void
    @State private var text = ""
    @State private var title = ""
    @State private var titleEdited = false
    @State private var choosing = false
    @State private var problem: String?

    private var words: Int { ProjectText.wordCount(text) }
    private var enough: Bool { words >= ProjectText.fewestWords && !ProjectText.passages(text).isEmpty }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if !replacing {
                    TextField("Title (optional)", text: Binding(get: { title }, set: { title = $0; titleEdited = true }))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Paste the description of your project: the aims and background of a grant proposal, a thesis plan or an abstract. The more of it that is about the subject, and the less about budgets and schedules, the better it works.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.callout)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .frame(minHeight: 220)
                    .onChange(of: text) { if !titleEdited { title = ProjectText.suggestedTitle(text) ?? "" } }
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
            .navigationTitle(replacing ? "Replace the text" : "New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(replacing ? "Replace" : "Add") { save(title, text); dismiss() }.disabled(!enough)
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

/// What the project is about, as phrases to follow, to choose from: counted in the text on this
/// device, or suggested by a language model when the user asks. Nothing is searched until it is added.
struct ProjectKeywordsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectID: String
    @State private var counted: [ProjectKeyword] = []
    @State private var asked: [ProjectKeyword] = []
    @State private var askedBy: String?
    @State private var working = false
    @State private var problem: String?
    @State private var chosen: Set<String> = []
    @State private var confirming = false
    @State private var loaded = false

    private var text: String { model.project(id: projectID)?.text ?? "" }

    private func fresh(_ words: [ProjectKeyword]) -> [ProjectKeyword] {
        words.filter { k in !model.settings.followedKeywords.contains { $0.phrase.lowercased() == k.id } }
    }

    var body: some View {
        NavigationStack {
            List {
                askSection
                if !asked.isEmpty {
                    Section {
                        ForEach(asked) { row($0, suggested: true) }
                    } header: {
                        Text("Suggested by \(askedBy ?? "the model")")
                    } footer: {
                        Text("A language model can be wrong, and can suggest what the text never says: the count is how often your text uses it.")
                    }
                }
                if loaded && counted.isEmpty && asked.isEmpty {
                    ContentUnavailableView("No repeated phrases", systemImage: "text.magnifyingglass",
                                           description: Text("The project does not return to any phrase often enough to suggest it. Add keywords by hand under Follow and mute."))
                }
                let phrases = counted.filter { $0.words > 1 }
                if !phrases.isEmpty {
                    Section {
                        ForEach(phrases) { row($0, suggested: false) }
                    } header: {
                        Text("Counted in your text")
                    } footer: {
                        Text("A keyword is searched in titles and abstracts and listed in full, so a broad one lists a great deal: leave out what is too general. You can narrow one afterwards, under Follow and mute, Keywords.")
                    }
                }
                let singles = counted.filter { $0.words == 1 }
                if !singles.isEmpty {
                    Section {
                        ForEach(singles) { row($0, suggested: false) }
                    } header: {
                        Text("Single words")
                    } footer: {
                        Text("A word on its own is searched everywhere it appears, so none is ticked.")
                    }
                }
            }
            .navigationTitle("Suggested keywords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(chosen.count)") {
                        let all = asked + counted
                        var seen: Set<String> = []
                        model.followKeywords(all.filter { chosen.contains($0.id) && seen.insert($0.id).inserted }.map(\.phrase))
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .task {
                counted = fresh(ProjectText.keywords(text))
                chosen = Set(counted.filter(\.selected).map(\.id))
                loaded = true
            }
            .sheet(isPresented: $confirming) {
                if let config = model.remoteSummary {
                    SendProjectSheet(config: config, excerpt: ProjectAI.excerpt(for: .service(config), text: text)) { excerpt in
                        ask(.service(config), excerpt: excerpt)
                    }
                }
            }
        }
    }

    @ViewBuilder private var askSection: some View {
        Section {
            if ProjectAI.onDeviceAvailable {
                Button { ask(.onDevice, excerpt: "") } label: { Label("Ask Apple's on-device model", systemImage: "sparkles") }
                    .disabled(working)
            }
            if let config = model.remoteSummary {
                Button { confirming = true } label: { Label("Ask \(config.displayName)…", systemImage: "arrow.up.forward.app") }
                    .disabled(working)
            }
            if !ProjectAI.onDeviceAvailable && model.remoteSummary == nil {
                Text("A language model can suggest better phrases than counting. This device has no Apple on-device model: set up an account of your own (Claude, ChatGPT or another model) under Summaries and AI in Tune to use one of those.")
                    .foregroundStyle(.secondary)
            }
            if working { HStack { ProgressView(); Text("Reading your project…").foregroundStyle(.secondary) } }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Ask a language model")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if ProjectAI.onDeviceAvailable {
                    Text("Apple's model runs on this device. It reads about \(ProjectText.wordCount(ProjectAI.excerpt(for: .onDevice, text: text))) words of your project and nothing is sent anywhere, not even to Apple.")
                }
                if let config = model.remoteSummary {
                    Text((config.provider == .other ? "" : "\(config.provider.name) is run by \(config.receiver). ") + "Asking sends part of your project to \(config.provider == .other ? config.receiver : "them")\(config.key.isEmpty ? "" : ", with your key,") after showing you exactly what. Nothing is sent unless you ask, and you are asked each time.")
                }
            }
        }
    }

    private func ask(_ route: ProjectAI.Route, excerpt: String) {
        working = true
        problem = nil
        let source = text
        Task {
            do {
                let found = try await ProjectAI.ask(route, excerpt: excerpt, text: source)
                asked = fresh(found)
                askedBy = route.name
                chosen.formUnion(asked.filter(\.selected).map(\.id))
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }

    private func row(_ k: ProjectKeyword, suggested: Bool) -> some View {
        Button {
            if chosen.contains(k.id) { chosen.remove(k.id) } else { chosen.insert(k.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: chosen.contains(k.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen.contains(k.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.phrase).foregroundStyle(.primary)
                    Text(k.count == 0 ? "not in your text" : k.count == 1 ? "1 time in your text" : "\(k.count) times in your text")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The screen between "Ask Claude" and the request: what leaves the device, who gets it, and the
/// text itself. Asked every time; nothing is remembered.
struct SendProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let config: RemoteSummaryConfig
    let excerpt: String
    let send: (String) -> Void

    /// A model on this device or the user's own network: the text does not go over the internet by this request.
    private var local: Bool { config.provider == .other && RemoteSummary.isLocal(config.endpointURL?.host ?? "") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(local ? "This leaves the app" : "This leaves your device", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text(local
                         ? "Part of your project description will be sent to \(config.receiver), a model on this device or your own network, as you set it up. Check where that service sends it on, if the text is confidential."
                         : "Part of your project description will be sent over the internet to \(config.receiver)\(config.provider == .other ? ", the service you set up," : " (\(config.provider.name)),") using your own account. \(config.receiver) processes it under the terms of that account; check them if the text is confidential.")
                    Text("The developer of Scrollar receives nothing. Only the text below is sent, with the instructions that ask for keywords, and your key. Headings, tables, links and reference lists are left out, but names and anything else in these passages are not. Do not send text you may not share with a service like this, such as a confidential proposal or someone else's data.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Show exactly what will be sent (\(ProjectText.wordCount(excerpt)) words)") {
                        Text(excerpt).font(.footnote).textSelection(.enabled)
                    }
                }
                Section {
                    Button("Send to \(config.receiver)") { send(excerpt); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(excerpt.isEmpty)
                    Button("Cancel", role: .cancel) { dismiss() }
                } footer: {
                    Text("You are asked each time. Counting phrases in the text, or asking Apple's on-device model, sends nothing.")
                }
            }
            .navigationTitle("Send to \(config.displayName)?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
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
            Text("A PDF opened in the reader is kept here, so it opens again at once, without a connection, and can be sent to a reference manager. When the limit is passed the ones you used longest ago are deleted first, and those of papers on your reading list or marked For me last. The system may also empty this space when the device is short of it. Nothing here is part of your settings or sync.")
        }

        Section {
            if let folder {
                let place = FolderPlace.describe(path: folder.path)
                LabeledContent("Folder", value: place.text)
                Label(place.iCloud ? "In iCloud Drive: your other devices see it once they choose the same folder."
                                   : "Not in iCloud Drive: only this device can see it.",
                      systemImage: place.iCloud ? "checkmark.icloud" : "exclamationmark.icloud")
                    .font(.footnote).foregroundStyle(place.iCloud ? Color.green : Color.orange)
                LabeledContent("Holds", value: folderUsage.count == 0 ? "Nothing yet" : "\(size(folderUsage.bytes)) in \(folderUsage.count) PDF" + (folderUsage.count == 1 ? "" : "s"))
                Picker("Put in it", selection: $policy) {
                    Text("Reading list and For me papers").tag(PDFFolder.Policy.saved)
                    Text("Every PDF I open").tag(PDFFolder.Policy.everything)
                }
                .onChange(of: policy) { PDFFolder.policy = policy }
                Button("Choose another folder…") { choosing = true }
                Button("Stop using this folder", role: .destructive) { PDFFolder.forget(); self.folder = nil }
            } else {
                Label("No folder chosen on this device: PDFs are not shared.", systemImage: "folder.badge.questionmark")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Choose a folder in iCloud Drive…") { choosing = true }
            }
        } header: {
            Text("Share PDFs between devices")
        } footer: {
            Text("Choose the same folder in iCloud Drive on each device: the choice is for this device only, so each one needs it. A PDF opened or added to the reading list on one is then there on the others, which look in the folder before downloading. The files are named after the paper, so you can find them in Files. Nothing here trims the folder or deletes from it, and it counts against your iCloud storage: delete files there when you want the room. Stopping only makes this device forget the folder.")
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
            Button("Delete all except the reading list", role: .destructive) { PDFCache.clear(keepingSaved: true); usage = PDFCache.usage() }
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
                LabeledContent("Folder", value: FolderPlace.describe(path: folder.path).text)
                Button("Choose another folder…") { choosing = true }
                Button("Stop using this folder", role: .destructive) { WatchedFolder.forget(); self.folder = nil }
            } else {
                Label("No folder chosen on this device.", systemImage: "folder.badge.questionmark")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Choose the folder…") { choosing = true }
            }
        } header: {
            Text("PDF folder for EndNote and Mendeley")
        } footer: {
            Text("EndNote can import PDFs from a folder by itself (its Settings, PDF Handling, Enable automatic importing; it looks when it opens, and moves what it imported into an Import subfolder), and Mendeley can watch one. Choose that folder here and a paper's Share menu gets Put the PDF in it. The manager reads the paper's details from the PDF, so a paper without a DOI may arrive without them; for those the .enw or .ris file is better. Zotero has no such folder: use Add to Zotero. This choice is for this device only.")
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, WatchedFolder.adopt(url) { folder = WatchedFolder.url }
        }
    }
}
