import SwiftUI
import UniformTypeIdentifiers

// The screens behind Tune's top list. Each one is a group of the sections that used to run on in one
// long scroll; what is in them, and what they say, is unchanged.

func tuneCount(_ n: Int) -> String { n == 0 ? "None" : "\(n)" }

func tuneEntityLink(_ title: String, kind: OpenAlexClient.EntityKind, items: Binding<[Entity]>,
                    byName: Bool = false, seedFor: ((Entity) -> Seed?)? = nil, explanation: String? = nil) -> some View {
    NavigationLink {
        EntityListView(title: title, kind: kind, items: items, byName: byName, seedFor: seedFor, explanation: explanation)
    } label: {
        LabeledContent(title, value: tuneCount(items.wrappedValue.count))
    }
}

extension AppModel {
    var syncStatusText: String {
        switch syncStatus {
        case .off: return "Off"
        case .syncing: return "Syncing…"
        case .idle(let date): return date.map { "Synced " + $0.formatted(.relative(presentation: .named)) } ?? "Ready"
        case .problem: return "Problem"
        }
    }
}

/// What the feed learns from: who you are, and the project you are about to work on.
struct YouScreen: View {
    @Environment(AppModel.self) private var appModel
    @State private var suggesting = false

    var body: some View {
        @Bindable var model = appModel
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
                    LabeledContent("Also learn from", value: tuneCount(model.settings.profileOrcids.count))
                }
                Button("Suggest what to follow…") { suggesting = true }
            } header: {
                Text("Your publications")
            } footer: {
                Text("Your publications, and those of anyone you add under Also learn from (a supervisor, say, if you have few papers yet), set what \"close to my work\" means, and \"Cited you\" tells you when someone cites yours. They can suggest what to follow, but nothing is followed unless it is in the Follow lists (Tune, Follow and mute), where you can remove it.")
            }

            ProjectSection()
        }
        .navigationTitle("You")
        .sheet(isPresented: $suggesting) { SuggestionsView() }
    }
}

/// What to look for, and what to leave out.
struct FollowScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        Form {
            Section {
                tuneEntityLink("Topics", kind: .topics, items: $model.settings.followedTopics, seedFor: Seed.forTopic,
                           explanation: "Papers OpenAlex files under a topic (each paper has up to three). A topic is broad, a few hundred papers a month, so what it finds is ranked with everything else and gets a small bonus, not listed in full. Searched in OpenAlex; a topic taken from a paper's MeSH headings is searched in Europe PMC.")
                tuneEntityLink("Journals", kind: .sources, items: $model.settings.followedJournals, byName: true,
                           seedFor: { .journal(id: $0.id, name: $0.name) },
                           explanation: "Everything these journals publish in your look-back window is kept in your feed, however low it would score. Large general journals publish a lot: remove any you do not want in full.")
                tuneEntityLink("Researchers", kind: .authors, items: $model.settings.followedAuthors, byName: true,
                           seedFor: { .author(id: $0.id, name: $0.name) },
                           explanation: "Every paper where this person appears anywhere in the author list is kept in your feed, however low it would score. Chosen from the search, they are matched by OpenAlex id; added by name, they are searched in Europe PMC and a namesake may slip in.")
                tuneEntityLink("Institutions", kind: .institutions, items: $model.settings.followedInstitutions, byName: true,
                           seedFor: { .institution(id: $0.id, name: $0.name) },
                           explanation: "Papers with an author at this institution or one of its departments or hospitals. An institution publishes in every field, so what it finds is ranked with everything else and gets a small bonus, not listed in full.")
                tuneEntityLink("Funders", kind: .funders, items: $model.settings.followedFunders, byName: true,
                           seedFor: { .funder(id: $0.id, name: $0.name) },
                           explanation: "Papers acknowledging this funder. A funder's papers are many and mixed, so what it finds is ranked with everything else and gets a small bonus, not listed in full.")
                NavigationLink {
                    KeywordListView(rules: $model.settings.followedKeywords)
                } label: {
                    LabeledContent("Keywords", value: tuneCount(model.settings.followedKeywords.count))
                }
            } header: {
                Text("Follow")
            } footer: {
                Text("Each follow searches for new papers. Everything that a journal, a researcher or a keyword you follow found is always in your feed, however low it scores. Topics, institutions and funders are too broad for that, so what they find is ranked with all the rest and gets a small bonus.")
            }

            Section("Mute") {
                tuneEntityLink("Journals", kind: .sources, items: $model.settings.mutedJournals, byName: true,
                           explanation: "Papers from these journals are removed before ranking, wherever they were found, including under Cited you.")
                tuneEntityLink("Researchers", kind: .authors, items: $model.settings.mutedAuthors,
                           explanation: "Papers with this person anywhere in the author list are removed. Matched by OpenAlex id, so papers that came only from Europe PMC are not affected.")
                tuneEntityLink("Topics", kind: .topics, items: $model.settings.mutedTopics,
                           explanation: "Papers OpenAlex files under any of these topics are removed. Matched by OpenAlex topic id, so papers that came only from Europe PMC are not affected.")
                NavigationLink {
                    MutedWordsView(words: $model.settings.mutedKeywords)
                } label: {
                    LabeledContent("Words", value: tuneCount(model.settings.mutedKeywords.count))
                }
            }
        }
        .navigationTitle("Follow and mute")
    }
}

func feedbackStatus(_ f: Feedback) -> String {
    "\(f.saved.count) on list · \(f.liked.count) for me · \(f.hidden.count) hidden"
}

/// How the feed is ordered: highlights, the kinds of paper, the sliders, and what you have told it.
struct RankingScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        Form {
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
                Text("One ranked list puts every paper where its score says, so a paper that cites you, one from a journal you follow and a close match all compete, and the line on each card says why it is there. In sections puts what cites you first, then what you follow, then the rest. Highlights are the few new papers above the feed that are very close to your work and also have something more: a journal or an author as strong as you set, a citation of your work, or something specific you follow. Impact is OpenAlex's two-year mean citedness (a high journal is about 5 or more); the h-index is checked only when the h-index option under Time and balance has fetched it, for the author you chose under Content and display, Posts.")
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
                Text("The h-index is that of the author(s) heading each post (see Content and display, Posts), taken from OpenAlex's own record of each author, so it can be wrong for common names. It favours established researchers over early-career ones, and varies by field. Authors with no figure are neither favoured nor penalised. Impact is OpenAlex's two-year mean citedness: how often a journal's recent papers are cited. It is an open measure close to the impact factor, which is Clarivate's and not available here. Preprints and journals without a figure are neither favoured nor penalised.")
            }

            Section {
                NavigationLink {
                    FeedbackScreen()
                } label: {
                    LabeledContent("Your feedback", value: feedbackStatus(model.settings.feedback))
                }
            } header: {
                Text("What you have told it")
            } footer: {
                Text("What is on your reading list, marked For me or hidden teaches the feed. Open it to see how much each counts, for how long, and what it is doing to the feed now.")
            }
        }
        .navigationTitle("Ranking")
    }
}

/// What is shown, and how a post looks.
struct ContentScreen: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("showCovers") private var showCovers = true

    var body: some View {
        @Bindable var model = appModel
        Form {
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
                Picker("Post is headed by", selection: $model.settings.byline) {
                    ForEach(BylineChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Journal banner on each post", isOn: $showCovers)
            } header: {
                Text("Posts")
            } footer: {
                Text("Badges show initials: open scholarly data has no author photographs. Which end of the author list leads depends on your field. The h-index option under Ranking follows this choice: the higher of the two when both are shown. A journal always has the same colour: a banner with its name and subject above the title. Off, the journal is a plain line.")
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
                Text("A post is seen once it has been on screen for a moment (about a second and a half, at least half of it showing): one you only flick past stays new. A paper you scrolled past sinks below the new ones, then drops out. One that stayed on screen for the number of seconds above, or that you marked For me, counts as studied: it sinks further and drops out after two days at most. The order changes when the feed is refreshed or reopened, never while you scroll. A paper you open or read in full leaves the feed and is kept under Reading list, Read.")
            }
        }
        .navigationTitle("Content and display")
    }
}

/// Everything about getting papers into a reference manager, and the PDFs kept for the reader.
struct ReferencesScreen: View {
    var body: some View {
        Form {
            ZoteroSection()
            LibraryFileSection()
            WatchedFolderSection()
            PDFStorageSection()
        }
        .navigationTitle("Reference managers and PDFs")
    }
}

struct SummariesScreen: View {
    var body: some View {
        Form { SummariesSection() }
            .navigationTitle("Summaries and AI")
    }
}

struct SourcesScreen: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var model = appModel
        Form {
            Section {
                Toggle("Europe PMC and PubMed", isOn: $model.settings.useEuropePMC)
                Toggle("OpenAlex", isOn: $model.settings.useOpenAlex)
                if model.settings.useOpenAlex {
                    OpenAlexKeyRows()
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Europe PMC covers PubMed and the preprint servers for biomedicine and needs nothing. OpenAlex covers every field and adds topics, authors by id, the impact and h-index options and more complete lists of your papers; it needs your own free key, which stays in this device's Keychain and is sent only to OpenAlex. A paper found by both is shown once.")
            }

            Section {
                Toggle("Crossref", isOn: $model.settings.useCrossref)
                Toggle("arXiv", isOn: $model.settings.useArXiv)
                Toggle("OSF preprints", isOn: $model.settings.useOSF)
            } header: {
                Text("More sources")
            } footer: {
                Text("Crossref has every DOI from every publisher, in every field, and needs nothing, but it can only look for a phrase in titles, a journal by its name and an author by their name, and about a third of its records carry an abstract. It is asked only when OpenAlex is off: it is the way to follow keywords and journals outside biomedicine without an OpenAlex key. arXiv covers physics, mathematics, computer science, statistics and quantitative biology, with the abstract, the day a paper is posted (OpenAlex can be days behind); it looks for a phrase and for an author's name, beside the other sources, and is asked no more than once in three seconds. Neither can list who cites a paper, or an institution's or a funder's papers. Both are free services that receive the phrases and names you follow, and nothing else. Thank you to arXiv for use of its open access interoperability. OSF preprints are PsyArXiv, SocArXiv, EdArXiv and the other preprint servers of the Open Science Framework, which matter most in psychology and the social sciences; Europe PMC carries some of them, not all. They are searched for a phrase in titles and abstracts only, at most once a second.")
            }
        }
        .navigationTitle("Sources")
    }
}

/// One file in iCloud Drive that keeps devices alike, and a file to go back to.
struct SyncBackupScreen: View {
    @Environment(AppModel.self) private var appModel
    @State private var creatingSyncFile = false
    @State private var joiningSyncFile = false
    @State private var creatingBackup = false
    @State private var restoringBackup = false
    @State private var pendingRestore: PendingRestore?
    @State private var restoreError: String?

    var body: some View {
        let model = appModel
        Form {
            Section {
                if let name = model.syncFileName {
                    LabeledContent("File", value: name)
                    LabeledContent("Status", value: model.syncStatusText)
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
                Text("Make the file in iCloud Drive on one device, then on each other device join that same file. Follows, mutes, keywords, sliders, the reading list, hidden papers and what you have read are shared and merged, so nothing is lost if you change things on two devices. The OpenAlex and Zotero keys and the feed itself stay on each device.")
            }

            Section {
                Button("Save a backup of my settings…") { creatingBackup = true }
                Button("Restore settings from a backup…") { restoringBackup = true }
            } header: {
                Text("Backup")
            } footer: {
                Text("A file you keep: your follows, mutes, keywords, sliders, and the reading list and hidden papers as they are now. It does not hold your OpenAlex or Zotero key, the feed, or what you have read. Restoring replaces your current settings after asking, and with syncing on the other devices follow. Sync keeps your devices the same; a backup is how you go back.")
            }
        }
        .navigationTitle("Sync and backup")
        .fileExporter(isPresented: $creatingSyncFile,
                      document: SyncFileDocument(data: creatingSyncFile ? model.initialSyncData() : Data()),
                      contentType: .json, defaultFilename: "Scrollar sync") { result in
            if case .success(let url) = result { Task { await model.adoptSyncFile(url) } }
        }
        .fileImporter(isPresented: $joiningSyncFile, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await model.adoptSyncFile(url) } }
        }
        // A view takes one exporter and one importer: the backup's are on the background.
        .background {
            Color.clear
                .fileExporter(isPresented: $creatingBackup,
                              document: SyncFileDocument(data: creatingBackup ? model.backupData() : Data()),
                              contentType: .json, defaultFilename: Backup.filename(at: Date())) { _ in }
                .fileImporter(isPresented: $restoringBackup, allowedContentTypes: [.json]) { result in
                    readBackup(result)
                }
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
                Text(when + what + " Your current follows, mutes, keywords and sliders, and your reading list and hidden papers, are replaced.")
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
}

/// The OpenAlex key, shown as what it is: stored or not, in use or not, and why not if it was refused.
/// The key itself is never shown whole; its last four characters let the user tell which one it is.
struct OpenAlexKeyRows: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var replacing = false

    private var masked: String { SecretText.masked(model.apiKey) }

    var body: some View {
        switch model.keySource {
        case .stored:
            LabeledContent("Key", value: masked)
            if replacing { entry } else {
                Button("Replace key…") { replacing = true }
                Button("Remove key", role: .destructive) { model.apiKey = "" }
            }
            status("Saved on this device and in use.", systemImage: "checkmark.circle.fill", color: .green)
        case .environment:
            status("A key from the development environment is in use. It is not saved.", systemImage: "info.circle", color: .secondary)
            entry
        case .none:
            entry
            status("No key: OpenAlex is skipped, and only the other sources answer.", systemImage: "exclamationmark.triangle.fill", color: .orange)
        }
        if let problem = model.keyProblem {
            status(problem, systemImage: "xmark.octagon.fill", color: .red)
        }
    }

    private var entry: some View {
        Group {
            SecureField("Paste your OpenAlex key", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save key") {
                model.apiKey = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = ""
                replacing = false
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Link("Get a free key", destination: URL(string: "https://openalex.org/settings/api")!)
        }
    }

    private func status(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage).font(.footnote).foregroundStyle(color)
    }
}
