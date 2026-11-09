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

    var body: some View {
        NavigationStack {
            Form {
                Section("Your feed") {
                    row("You", "person.crop.circle", status: youStatus) { YouScreen() }
                    row("Follow and mute", "binoculars", status: followStatus) { FollowScreen() }
                    row("Ranking", "arrow.up.arrow.down", status: rankingStatus) { RankingScreen() }
                    row("Content and display", "text.alignleft", status: contentStatus) { ContentScreen() }
                }
                Section("Connections and data") {
                    row("Reference managers and PDFs", "books.vertical", status: referencesStatus) { ReferencesScreen() }
                    row("Summaries and AI", "sparkles", status: summariesStatus) { SummariesScreen() }
                    row("Sources", "network", status: sourcesStatus) { SourcesScreen() }
                    row("Sync and backup", "icloud", status: appModel.syncStatusText) { SyncBackupScreen() }
                }
            }
            .navigationTitle("Tune")
        }
    }

    private func row<D: View>(_ title: String, _ symbol: String, status: String,
                              @ViewBuilder _ destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
        } label: {
            LabeledContent {
                Text(status).lineLimit(1)
            } label: {
                Label(title, systemImage: symbol)
            }
        }
    }

    // What each row says about the screen behind it, so most of the time there is no need to open it.

    private var youStatus: String {
        let s = appModel.settings
        var parts: [String] = []
        if let orcid = s.orcid, Orcid.normalised(orcid) != nil { parts.append("ORCID") }
        if appModel.project != nil { parts.append("project") }
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
        return s.feedOrder.title + " · " + (s.highlightCount == 0 ? "no highlights" : "\(s.highlightCount) highlights")
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
        var parts: [String] = []
        if appModel.zotero != nil { parts.append("Zotero") }
        if appModel.libraryFile != nil { parts.append("library file") }
        return parts.isEmpty ? "None connected" : parts.joined(separator: " · ")
    }

    private var summariesStatus: String {
        if Summarizer.isAvailable { return "Apple's model" }
        return appModel.remoteSummary?.provider.name ?? "None"
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
            Text("Your most recently added items (title, abstract and tags) are read and compared on this device, as your reading list is, to judge which new papers are close to your work. Only the newest ones count, so what you are reading now outweighs what you filed years ago. Nothing is followed because of it: Follow lists stay yours. The key stays in this device's Keychain and is sent only to Zotero. A read-only key is enough to learn from the library; to also save papers from a post it must be allowed to write. A PDF attached to an item is stored in your Zotero file storage and counts against its quota (300 MB on the free plan); if it is full the paper is still saved, without the PDF.")
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
            Text("Matching uses a text model on this device: Apple's sentence model where it has one, otherwise its contextual model, which is fetched once and does not need Apple Intelligence; with neither, words alone. A key is not a chat subscription: it is a separate, pay-per-use account of your own (Claude or OpenAI). When it is set up, the title and abstract of a paper that stays on screen are sent to that service, and nothing else, except that you can also ask it to suggest keywords from a project you pasted (under Your project): then an excerpt of the project is sent, after a warning that shows exactly what goes, each time you ask. Each takeaway costs a fraction of a cent to a cent or two, depending on the model: a smaller one costs far less, and Claude Haiku (claude-haiku-5-5) is the cheapest Claude. At most \(Summarizer.remoteLimit) are written per launch, and each is kept, so a paper is never asked for twice. The key stays in this device's Keychain and is sent only to that service. A device that has Apple's model uses it instead and sends nothing.")
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
                Text("\(ProjectText.wordCount(project.text)) words, \(passageCount(project.text)) read, pasted \(pasted(project.addedAt)).")
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
            Text("Paste a grant proposal, a thesis plan or an abstract: what you are about to work on, before there are papers to show it. Papers close to it rank higher, and it can suggest keywords to follow, which you choose from a list. It is read on this device and kept only here: it is not synced and not in the settings file you can export. It is sent to no service unless you ask Claude or ChatGPT, with your own key, to suggest keywords, and then only after a warning that shows exactly what goes. Apple's on-device model, where the device has one, reads it without sending anything. Only a keyword you choose to follow is searched, like any other.")
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

    private func passageCount(_ text: String) -> String {
        let n = ProjectText.passages(text).count
        return n == 1 ? "1 passage" : "\(n) passages"
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

/// What the project is about, as phrases to follow, to choose from: counted in the text on this
/// device, or suggested by a language model when the user asks. Nothing is searched until it is added.
struct ProjectKeywordsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var counted: [ProjectKeyword] = []
    @State private var asked: [ProjectKeyword] = []
    @State private var askedBy: String?
    @State private var working = false
    @State private var problem: String?
    @State private var chosen: Set<String> = []
    @State private var confirming = false
    @State private var loaded = false

    private var text: String { model.project?.text ?? "" }

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
                Button { confirming = true } label: { Label("Ask \(config.provider.name)…", systemImage: "arrow.up.forward.app") }
                    .disabled(working)
            }
            if !ProjectAI.onDeviceAvailable && model.remoteSummary == nil {
                Text("A language model can suggest better phrases than counting. This device has no Apple on-device model: set up your own Claude or ChatGPT key under Summaries and AI in Tune to use one of those.")
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
                    Text("\(config.provider.name) is run by \(config.provider.company). Asking sends part of your project to them, with your key, after showing you exactly what. Nothing is sent unless you ask, and you are asked each time.")
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("This leaves your device", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text("Part of your project description will be sent over the internet to \(config.provider.company) (\(config.provider.name)), using your own key. \(config.provider.company) processes it under the terms of your account with them; check them if the text is confidential.")
                    Text("The developer of Scrollar receives nothing. Only the text below is sent, with the instructions that ask for keywords, and your key. Headings, tables, links and reference lists are left out, but names and anything else in these passages are not. Do not send text you may not share with a service like this, such as a confidential proposal or someone else's data.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Show exactly what will be sent (\(ProjectText.wordCount(excerpt)) words)") {
                        Text(excerpt).font(.footnote).textSelection(.enabled)
                    }
                }
                Section {
                    Button("Send to \(config.provider.company)") { send(excerpt); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(excerpt.isEmpty)
                    Button("Cancel", role: .cancel) { dismiss() }
                } footer: {
                    Text("You are asked each time. Counting phrases in the text, or asking Apple's on-device model, sends nothing.")
                }
            }
            .navigationTitle("Send to \(config.provider.name)?")
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
                LabeledContent("Folder", value: folder.lastPathComponent)
                LabeledContent("Holds", value: folderUsage.count == 0 ? "Nothing yet" : "\(size(folderUsage.bytes)) in \(folderUsage.count) PDF" + (folderUsage.count == 1 ? "" : "s"))
                Picker("Put in it", selection: $policy) {
                    Text("Reading list and For me papers").tag(PDFFolder.Policy.saved)
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
            Text("Choose the same folder in iCloud Drive on each device. A PDF opened or added to the reading list on one is then there on the others, which look in the folder before downloading. The files are named after the paper, so you can find them in Files. Nothing here trims the folder or deletes from it, and it counts against your iCloud storage: delete files there when you want the room. Stopping only makes this device forget the folder.")
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
