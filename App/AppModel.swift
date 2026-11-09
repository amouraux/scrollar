import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.andremouraux.scrollar", category: "feed")

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case failed(String)
    }

    /// What is on screen: the feed sorted into new, earlier and read. It changes
    /// when a feed is loaded or the user asks for the new papers, never as they
    /// scroll, so no card moves while it is being looked at.
    /// What is on screen: highlights, then the feed in the order the user chose, sorted into new,
    /// earlier and read. It changes when a feed is loaded or the user asks for the new papers,
    /// never as they scroll, so no card moves while it is being looked at.
    typealias Layout = FeedLayout

    var settings: FeedSettings {
        didSet {
            store.saveSettings(settings)
            // Whatever differs from what was recorded was decided here, just now.
            ledger.reconcile(settings, at: Date())
            store.saveLedger(ledger)
            if !applyingSync { syncSoon(after: 3) }
            // Following something new or muting something means fetching again;
            // hiding one paper does not.
            if settings.forRanking != oldValue.forRanking { needsRefresh = true }
            let layoutChanged = settings.seenExpiryDays != oldValue.seenExpiryDays
                || settings.feedOrder != oldValue.feedOrder
                || settings.highlightCount != oldValue.highlightCount
                || settings.highlightCloseness != oldValue.highlightCloseness
                || settings.highlightImpact != oldValue.highlightImpact
                || settings.highlightAuthorH != oldValue.highlightAuthorH
                || settings.dwellSeconds != oldValue.dwellSeconds
            if layoutChanged { rearrange() }
        }
    }

    var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            Keychain.save(apiKey)
            if oldValue.isEmpty { needsRefresh = true }
        }
    }

    private(set) var layout = Layout()
    /// The connected Zotero account, with its key: from the Keychain, never from a file.
    private(set) var zotero: ZoteroAccount?
    /// The RIS or BibTeX export last imported, for managers that have no API to read.
    private(set) var libraryFile: LibraryFile?
    /// A research project the user pasted (a proposal, a plan): its passages stand for what they are
    /// into, and its phrases can be offered as keywords. On this device only.
    private(set) var project: ProjectFile?
    /// A Claude or ChatGPT account for takeaways on a device with no on-device model; from the Keychain.
    private(set) var remoteSummary: RemoteSummaryConfig?
    /// Why takeaways from it are not arriving, if they are not; shown in Tune.
    private(set) var summaryProblem: String?
    /// What the last read of the library did, for Tune; nil before one.
    private(set) var zoteroStatus: String?
    /// A one-line answer to something the user just did, shown briefly over the feed.
    private(set) var toast: String?
    /// The paper open in the reader pane, if the window is wide enough to have one.
    private(set) var readerPaper: Paper?
    /// Set by the feed while it has room for the pane; a card taps through to the pane only then.
    var readerShown = false
    /// Asked of the feed column after a keyboard step, so the paper comes into view. A tap never
    /// sets it: the post under the pointer is already where the reader wants it.
    private(set) var readerScroll: ScrollRequest?
    struct ScrollRequest: Equatable { let key: String; let id = UUID() }
    private(set) var history: History
    private(set) var authorName: String?
    private(set) var updated: Date?
    private(set) var usedEmbeddings = true
    /// "apple-sentence", "apple-contextual", or nil when similarity came from word counts alone.
    private(set) var embedderID: String?
    private(set) var phase: Phase = .idle
    /// Takeaways written by the on-device model, by paper. Where there is none,
    /// a post shows sentences chosen from the abstract instead.
    private(set) var summaries: [String: String]
    private var summaryFailures: Set<String> = []
    private var saveSummariesTask: Task<Void, Never>?
    /// How many papers a background refresh found that are not on screen yet.
    private(set) var pendingNew = 0
    /// Something the user should be told once, such as a settings file that would not load.
    var notice: String?
    var needsRefresh = false

    /// The whole ranked feed behind `layout`.
    private var citedYou: [RankedPaper] = []
    private var forYou: [RankedPaper] = []
    private var pending: FeedResult?
    private var pendingBuiltFor: FeedSettings?
    /// What the cached feed covers, so the next refresh can ask for less.
    private var builtWith: FeedSettings?
    private var fetchedThrough: Date?
    private var fullBuildAt: Date?
    /// Days held beyond the look-back, from scrolling to the end of the feed.
    private(set) var extraDays = 0
    /// The last attempt to go further back failed; the footer offers a retry instead of
    /// trying again by itself, which would loop on a broken connection.
    private(set) var olderFailed = false
    private var saveHistoryTask: Task<Void, Never>?
    private let store = Store()

    // MARK: Sync state
    enum SyncStatus: Equatable {
        case off
        case syncing
        case idle(Date?)
        case problem(String)
    }

    private(set) var syncStatus: SyncStatus = .off
    private(set) var syncFileName: String?
    private var syncFile: SyncFile?
    /// What this device has decided and when: the half of the sync that is not the file.
    private var ledger = SyncDocument()
    private var syncing = false
    /// Set while a merge from the other device is applied, so that is not mistaken for an edit here.
    private var applyingSync = false
    private var resuming = false
    private var filling = false
    private var settingsSyncTask: Task<Void, Never>?
    private var historySyncTask: Task<Void, Never>?

    init() {
        switch store.loadSettings() {
        case .loaded(let s):
            settings = s
        case .unreadable(let copy):
            settings = FeedSettings()
            notice = "Your settings file could not be read, so defaults are in use. A copy was kept as \(copy)."
        case .none:
            var s = FeedSettings()
            #if DEBUG
            // Lets a simulator run start with a profile without typing into the app.
            s.orcid = ProcessInfo.processInfo.environment["SCROLLAR_ORCID"]
            #endif
            settings = s
        }
        apiKey = Keychain.load()
        remoteSummary = Keychain.load(service: Keychain.summaries).data(using: .utf8).flatMap { try? JSONDecoder().decode(RemoteSummaryConfig.self, from: $0) }
        libraryFile = store.loadLibraryFile()
        project = store.loadProject()
        zotero = Keychain.load(service: Keychain.zotero).data(using: .utf8).flatMap { try? JSONDecoder().decode(ZoteroAccount.self, from: $0) }
        history = store.loadHistory()
        summaries = store.loadSummaries()
        if let cached = store.loadFeed() {
            citedYou = cached.citedYou.map { RankedPaper(paper: $0.paper.withPlainText, score: $0.score, similarity: $0.similarity) }
            forYou = cached.forYou.map { RankedPaper(paper: $0.paper.withPlainText, score: $0.score, similarity: $0.similarity) }
            authorName = cached.authorName
            updated = cached.date
            usedEmbeddings = cached.usedEmbeddings ?? true
            embedderID = cached.embedderID ?? (usedEmbeddings ? CachingEmbedder.legacyModelID : nil)
            builtWith = cached.builtWith
            fetchedThrough = cached.fetchedThrough
            fullBuildAt = cached.fullBuildAt
            extraDays = cached.extraDays ?? 0
            // A follow added just before the app was closed must not wait six hours.
            if let built = cached.builtWith, built.forRanking != settings.forRanking { needsRefresh = true }
        }
        // Which author heads a post used to be kept in the app's defaults. It is a
        // setting now, because the h-index ranking follows it; carry the old choice over.
        if let old = UserDefaults.standard.string(forKey: "byline") {
            if let choice = BylineChoice(rawValue: old) {
                settings.byline = choice
                store.saveSettings(settings)
            }
            UserDefaults.standard.removeObject(forKey: "byline")
        }
        if let saved = store.loadLedger() {
            ledger = saved
            ledger.reconcile(settings, at: Date())
        } else {
            // A first run: the settings are as old as their file, so a device that was
            // edited later, anywhere, outranks them, and a fresh install's defaults never do.
            ledger.reconcile(settings, at: store.settingsModified ?? .distantPast)
        }
        store.saveLedger(ledger)
        syncFile = SyncFile.stored()
        syncFileName = syncFile?.name
        syncStatus = syncFile == nil ? .off : .idle(nil)
        rearrange()
        if let remote = remoteSummary { Task { await Summarizer.shared.configure(remote: remote) } }
        PDFCache.savedKeys = { [weak self] in
            guard let f = self?.settings.feedback else { return [] }
            return f.saved.map(\.id) + f.liked.map(\.id)
        }
    }

    /// The key to use. In a debug build an environment variable stands in when
    /// nothing is saved, so a simulator can be tried without the key ever being
    /// typed, stored or compiled in.
    var effectiveKey: String {
        #if DEBUG
        if apiKey.isEmpty { return ProcessInfo.processInfo.environment["SCROLLAR_OPENALEX_KEY"] ?? "" }
        #endif
        return apiKey
    }

    var hasKey: Bool { !effectiveKey.isEmpty }

    /// Whether OpenAlex will be asked: it needs the user's key and their say-so.
    var usesOpenAlex: Bool { settings.useOpenAlex && hasKey }

    /// A feed can be built when some source is on. Europe PMC needs nothing.
    var canBuild: Bool { usesOpenAlex || settings.useEuropePMC }

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var openAlex: OpenAlexClient { OpenAlexClient(apiKey: effectiveKey) }

    // MARK: Feed

    /// Open the app: show what is cached, and fetch only if it is old or the
    /// settings changed since. A fetch the user did not ask for waits behind a
    /// "new papers" pill instead of replacing the list they are about to read.
    func refreshIfStale() async {
        guard canBuild else { return }
        if needsRefresh {
            await refresh()
        } else if updated.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            await refresh(userInitiated: false)
        }
    }

    /// Whether the end of the feed can go further back: a feed is held to build on, and
    /// less than a year of it is.
    var canLoadOlder: Bool {
        // What is held must have been fetched for today's follows and filters, or the older
        // papers would be merged into a feed whose reasons no longer apply.
        guard canBuild, fetchedThrough != nil, fullBuildAt != nil, let built = builtWith,
              !(citedYou.isEmpty && forYou.isEmpty), built.forFetching == settings.forFetching else { return false }
        return settings.daysBack + extraDays < Incremental.furthestDays
    }

    /// The reader reached the end: fetch the days before the ones held and add them below.
    func loadOlder() async {
        guard canLoadOlder, !isLoading, !olderFailed else { return }
        await refresh(userInitiated: true, older: true)
    }

    func retryOlder() {
        olderFailed = false
        Task { await loadOlder() }
    }

    func refresh(userInitiated: Bool = true, older: Bool = false) async {
        if isLoading { return }
        let key = effectiveKey
        guard canBuild else {
            phase = .failed("No source is on. Turn on Europe PMC, or add your OpenAlex key, in Tune.")
            return
        }
        let previous = previousFeed()
        if older && previous == nil { return }
        phase = .loading(older ? "Looking further back…" : "Starting…")
        if !older { needsRefresh = false }
        let settings = self.settings
        // Going back asks for nothing from Zotero: the copy already held ranks what it fetches.
        let library = await zoteroTexts(allowNetwork: !older) + libraryFileTexts()
        let projectPassages = project.map { ProjectText.passages($0.text) } ?? []
        let useOpenAlex = usesOpenAlex
        // What this feed is built for, taken now: the user may change a follow
        // while it runs, and the result must not claim to match that.
        let builtFor = settings.withoutFeedback
        let cachedVectors = store.loadEmbeddings()
        let report: (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.progress(message) }
        }

        do {
            // The ranking is CPU work, so it runs off the main thread.
            let (result, vectors) = try await Task.detached(priority: .userInitiated) { () -> (FeedResult, Data?) in
                // Apple's sentence model, else its contextual one (fetched once if need be), else none.
                let cache = await TextEmbedders.best().map { CachingEmbedder($0, stored: cachedVectors) }
                let engine = FeedEngine(openAlex: useOpenAlex ? OpenAlexClient(apiKey: key) : nil,
                                        europePMC: settings.useEuropePMC ? EuropePMCClient() : nil,
                                        embedder: cache, log: report)
                let result = try await engine.build(settings, previous: previous, older: older, library: library, project: projectPassages)
                let used = result.profileTexts + (result.citedYou + result.forYou).map { Ranker.text($0.paper) }
                return (result, cache?.snapshot(keeping: used))
            }.value

            phase = .idle
            olderFailed = false
            if let vectors { store.saveEmbeddings(vectors) }
            if userInitiated || layout.isEmpty {
                apply(result, builtFor: builtFor)
            } else {
                stage(result, builtFor: builtFor)
            }
        } catch {
            // Keep showing the last feed; only say what went wrong.
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
            if older { olderFailed = true }
            phase = .failed("\(error)")
        }
    }

    /// Show what a background refresh found.
    func applyPending() {
        guard let result = pending, let builtFor = pendingBuiltFor else { return }
        apply(result, builtFor: builtFor)
    }

    /// What the last fetch covers, if it can be built on.
    private func previousFeed() -> PreviousFeed? {
        guard let through = fetchedThrough, let full = fullBuildAt, let built = builtWith,
              !(citedYou.isEmpty && forYou.isEmpty) else { return nil }
        return PreviousFeed(papers: (citedYou + forYou).map(\.paper),
                            fetchedThrough: through, fullBuildAt: full, builtWith: built, extraDays: extraDays)
    }

    private func apply(_ result: FeedResult, builtFor: FeedSettings) {
        pending = nil
        pendingBuiltFor = nil
        pendingNew = 0
        citedYou = result.citedYou
        forYou = result.forYou
        authorName = result.author?.name
        updated = Date()
        usedEmbeddings = result.usedEmbeddings
        embedderID = result.embedderID

        // Advance what the cache covers only if every seed answered. A fetch with a
        // gap must be asked for again; a full build with a gap cannot be built on at all.
        builtWith = builtFor
        extraDays = result.extraDays
        if case .older = result.mode {
            // Going back says nothing about how recent what is held is.
        } else if result.complete {
            fetchedThrough = result.fetchedAt
            if !result.mode.isIncremental { fullBuildAt = result.fetchedAt }
        } else if !result.mode.isIncremental {
            fetchedThrough = nil
            fullBuildAt = nil
        }
        // Settings changed while this was building: it is already out of date.
        if settings.forRanking != builtFor.forRanking { needsRefresh = true }

        history.prune(now: Date())
        let keys = Set((citedYou + forYou).map { $0.paper.dedupeKey })
        summaries = summaries.filter { keys.contains($0.key) }
        store.saveSummaries(summaries)
        rearrange()
        store.saveHistory(history)
        store.saveFeed(CachedFeed(citedYou: citedYou, forYou: forYou, authorName: authorName,
                                  date: Date(), usedEmbeddings: result.usedEmbeddings, embedderID: result.embedderID,
                                  builtWith: builtFor, fetchedThrough: fetchedThrough, fullBuildAt: fullBuildAt,
                                  extraDays: extraDays))
    }

    /// Keep a refresh aside and count what is new in it, without touching the screen.
    private func stage(_ result: FeedResult, builtFor: FeedSettings) {
        let onScreen = Set(layout.all.map { $0.paper.dedupeKey })
        let incoming = makeLayout(citedYou: result.citedYou, forYou: result.forYou, now: Date())
        let fresh = incoming.highlights.map(\.ranked) + [incoming.feed, incoming.citedYou, incoming.following, incoming.forYou].flatMap(\.fresh)
        let count = fresh.filter { !onScreen.contains($0.paper.dedupeKey) }.count
        if count == 0 {
            apply(result, builtFor: builtFor)   // nothing the user would notice changing
        } else {
            pending = result
            pendingBuiltFor = builtFor
            pendingNew = count
        }
    }

    private func rearrange() {
        layout = makeLayout(citedYou: citedYou, forYou: forYou, now: Date())
    }

    /// What is on screen for a ranked feed: the news about the user's work, everything
    /// their follows found (if they asked for that section), and the rest in rank order.
    private func makeLayout(citedYou: [RankedPaper], forYou: [RankedPaper], now: Date) -> Layout {
        FeedLayout.make(citedYou: citedYou, forYou: forYou, history: history, settings: settings, now: now)
    }

    private func progress(_ message: String) {
        log.info("\(message, privacy: .public)")
        if case .loading = phase { phase = .loading(message) }
    }

    // MARK: Takeaways

    /// What a post says: the model's takeaway if there is one, else the
    /// sentences the abstract itself offers.
    func takeaway(for p: Paper) -> (text: String, writtenByModel: Bool)? {
        if let written = summaries[p.dedupeKey] { return (written, true) }
        if let chosen = Summary.takeaway(from: p.abstract) { return (chosen, false) }
        return nil
    }

    /// Ask the model for a post that has been on screen a moment. It runs when the
    /// post appears and is cancelled when it leaves, so scrolling fast costs nothing.
    func writeTakeaway(for p: Paper) async {
        let key = p.dedupeKey
        guard summaries[key] == nil, !summaryFailures.contains(key),
              let abstract = p.abstract, canSummarise, summaryProblem == nil else { return }
        switch await Summarizer.shared.takeaway(title: p.title, abstract: abstract) {
        case .text(let text):
            summaries[key] = text
            saveSummariesSoon()
        case .failed(let why):
            // A refused key would be refused for every paper: say so once, and stop asking.
            if !Task.isCancelled { summaryProblem = why }
        case .declined:
            if !Task.isCancelled { summaryFailures.insert(key) }   // do not ask again this run
        case .unavailable:
            break
        }
    }

    // MARK: Takeaways from the user's own model

    /// What judged how close the papers are to the user's work, for Tune: this is the answer to
    /// "why does it say it matches by words only".
    var embeddingDescription: String {
        switch embedderID {
        case "apple-sentence": return "Apple's sentence model"
        case "apple-contextual": return "Apple's contextual text model"
        default: return updated == nil ? "not built yet" : "word counts only"
        }
    }

    /// Something can write takeaways: the on-device model, or an account set up in Tune.
    var canSummarise: Bool { Summarizer.isAvailable || remoteSummary != nil }

    /// What the note under an opened paper says wrote its takeaway.
    var summaryNote: String {
        if Summarizer.isAvailable { return "written on this device by Apple's language model" }
        if let remote = remoteSummary { return "written by \(remote.provider.name) from the title and abstract, with the key you set up in Tune" }
        return "written by a language model"
    }

    /// Try the account with one small request; keep it only if that works, so a wrong key or model
    /// name is found now and not by a feed of missing takeaways.
    func setUpRemoteSummary(_ config: RemoteSummaryConfig) async throws {
        let sample = "Patients with chronic back pain showed a reduced late positive potential and an enhanced early gamma response to painful heat. These responses correlated with pain interference but not with pain intensity."
        guard try await RemoteSummary.takeaway(config, title: "EEG responses in chronic back pain", abstract: sample) != nil else {
            throw RemoteSummaryError.unreadable
        }
        guard let data = try? JSONEncoder().encode(config) else { return }
        Keychain.save(String(decoding: data, as: UTF8.self), service: Keychain.summaries)
        remoteSummary = config
        summaryProblem = nil
        summaryFailures = []
        await Summarizer.shared.configure(remote: config)
    }

    func clearRemoteSummary() {
        Keychain.save("", service: Keychain.summaries)
        remoteSummary = nil
        summaryProblem = nil
        Task { await Summarizer.shared.configure(remote: nil) }
    }

    /// Let the next card try again after the user has fixed a key in Tune.
    func clearSummaryProblem() { summaryProblem = nil; summaryFailures = [] }

    private func saveSummariesSoon() {
        saveSummariesTask?.cancel()
        saveSummariesTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.store.saveSummaries(self.summaries)
        }
    }

    // MARK: Sync between devices

    // MARK: Backup and preview

    /// The settings as a file to keep. Not the key, the feed or the read record: see `SettingsBackup`.
    func backupData() -> Data { (try? Backup.encode(settings, at: Date())) ?? Data() }

    /// Replace the settings with a backup's. It goes through the same path as any edit, so it is
    /// saved, recorded for sync and fetched for.
    func restore(_ restored: FeedSettings) { settings = restored }

    /// What following `seed` would find, without following it.
    func preview(_ seed: Seed, rule: KeywordRule? = nil) async throws -> SeedPreview {
        let engine = FeedEngine(openAlex: usesOpenAlex ? openAlex : nil,
                                europePMC: settings.useEuropePMC ? EuropePMCClient() : nil, embedder: nil)
        return try await engine.preview(seed, rule: rule, settings: settings)
    }

    /// What the "create the sync file" dialog saves: everything, as it is now.
    func initialSyncData() -> Data {
        var doc = ledger
        doc.history = history
        return (try? doc.encoded()) ?? Data()
    }

    /// Use this file from now on, and merge what is in it with what is here: nothing
    /// is replaced, so a second device that joins a file loses nothing of its own.
    func adoptSyncFile(_ url: URL) async {
        guard let file = SyncFile.adopt(url) else {
            syncStatus = .problem("That file could not be used for syncing.")
            return
        }
        syncFile = file
        syncFileName = file.name
        await syncNow(rearrange: true)
    }

    func stopSyncing() {
        settingsSyncTask?.cancel()
        historySyncTask?.cancel()
        SyncFile.forget()
        syncFile = nil
        syncFileName = nil
        syncStatus = .off
    }

    private func syncSoon(after seconds: Double) {
        guard syncFile != nil else { return }
        settingsSyncTask?.cancel()
        settingsSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func syncHistorySoon(after seconds: Double) {
        guard syncFile != nil else { return }
        historySyncTask?.cancel()
        historySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Read the shared file, merge it with this device's decisions, apply what is new
    /// here and write the result back if it differs. `rearrange` re-sorts the feed
    /// into new, earlier and read, which is only done when the user has just come back.
    func syncNow(rearrange sort: Bool = false) async {
        guard let file = syncFile, !syncing else { return }
        syncing = true
        syncStatus = .syncing
        defer { syncing = false }

        let outcome = await Task.detached(priority: .utility) { file.read() }.value
        if let problem = outcome.problem {
            syncStatus = .problem(problem.message)
            return
        }

        // Merge against the state as it is now: the user may have edited while the file was read.
        ledger.reconcile(settings, at: Date())
        var merged = ledger
        for doc in [outcome.main].compactMap({ $0 }) + outcome.conflicts { merged = merged.merged(with: doc) }
        var mergedHistory = history.merged(with: merged.history)
        mergedHistory.prune(now: Date())

        // What goes back into the file. The record kept here holds settings only; history is its own file.
        var document = merged
        document.history = mergedHistory
        merged.history = History()
        // Record first, then apply: settings that came from the other device are then
        // already in the record and are not stamped as edits made here.
        let newSettings = merged.apply(to: settings)
        ledger = merged
        store.saveLedger(ledger)
        if newSettings != settings {
            applyingSync = true
            settings = newSettings        // saves, and asks for a refresh if a follow changed
            applyingSync = false
        }
        if mergedHistory != history {
            history = mergedHistory
            store.saveHistory(history)
            if sort { rearrange() }
        }

        if outcome.main != document || outcome.hadConflictVersions {
            guard let data = try? document.encoded() else { syncStatus = .problem("Could not prepare the sync file."); return }
            let conflicts = outcome.hadConflictVersions
            let wrote = await Task.detached(priority: .utility) { file.write(data, resolvingConflicts: conflicts) }.value
            if !wrote { syncStatus = .problem("The sync file could not be written. It will be tried again."); return }
        }
        syncStatus = .idle(Date())
    }

    /// What happens when the app is opened or comes back: the other device is read, an empty
    /// follow list is filled from the publications, and a stale feed is refreshed, in that order,
    /// because each depends on the one before. Launch and returning both ask for this, at nearly
    /// the same moment; the second finds the first at work and leaves it to finish, or the feed
    /// would be built before the follows were in.
    func resume() async {
        guard !resuming else { return }
        resuming = true
        defer { resuming = false }
        await syncNow(rearrange: true)
        await fillFromProfileIfNeeded()
        await refreshIfStale()
    }

    // MARK: Following what the user's publications suggest

    struct ProfileSuggestions {
        var byKind: [SuggestionKind: [ProfileSuggestion]]
        /// Whose publications these came from.
        var names: [String]
        var paperCount: Int
    }

    enum ProfileError: LocalizedError {
        case noOrcid
        case noSource
        var errorDescription: String? {
            switch self {
            case .noOrcid: return "Add your ORCID iD, or someone to learn from, first."
            case .noSource: return "No source is on. Turn on Europe PMC, or add an OpenAlex key, in Tune."
            }
        }
    }

    /// Read the publications of the user and of anyone they added, and suggest what to
    /// follow. Nothing is followed until the user chooses it.
    func loadProfileSuggestions() async throws -> ProfileSuggestions {
        guard canBuild else { throw ProfileError.noSource }
        let fetcher = ProfileFetcher(openAlex: usesOpenAlex ? openAlex : nil,
                                     europePMC: settings.useEuropePMC ? EuropePMCClient() : nil)
        var sources: [ProfileSourceWorks] = []
        var names: [String] = []
        var sizes: [String: Int] = [:]
        var failure: Error?
        if let orcid = settings.orcid.flatMap(Orcid.normalised) {
            do {
                let (name, works, journalSizes) = try await fetcher.works(orcid: orcid)
                sources.append(ProfileSourceWorks(label: "you", works: works))
                names.append(name)
                sizes.merge(journalSizes) { a, _ in a }
            } catch { failure = error }
        }
        for extra in settings.profileOrcids {
            do {
                let (name, works, journalSizes) = try await fetcher.works(orcid: extra.orcid)
                sources.append(ProfileSourceWorks(label: extra.label.isEmpty ? name : extra.label, works: works))
                sizes.merge(journalSizes) { a, _ in a }
                names.append(extra.label.isEmpty ? name : "\(extra.label) (\(name))")
            } catch { failure = failure ?? error }
        }
        if sources.isEmpty { throw failure ?? ProfileError.noOrcid }
        let year = Calendar.current.component(.year, from: Date())
        var byKind = ProfileAnalysis.suggestions(sources, currentYear: year, journalSizes: sizes)
        // How broad each candidate keyword is, so one that matches hundreds of papers a month
        // is offered with a warning and not ticked. Only OpenAlex can say; without it, no warning.
        if usesOpenAlex, let phrases = byKind[.keyword]?.map(\.entity.name), !phrases.isEmpty {
            let monthAgo = Ranker.dayString(Date().addingTimeInterval(-30 * 86_400))
            let volumes = await openAlex.keywordVolumes(phrases: phrases, since: monthAgo)
            if !volumes.isEmpty {
                byKind = ProfileAnalysis.suggestions(sources, currentYear: year, journalSizes: sizes, keywordVolumes: volumes)
            }
        }
        return ProfileSuggestions(byKind: byKind, names: names,
                                  paperCount: sources.reduce(0) { $0 + $1.works.count })
    }

    func isFollowed(_ s: ProfileSuggestion) -> Bool {
        switch s.kind {
        case .topic: return settings.followedTopics.contains { $0.id == s.entity.id }
        case .keyword: return settings.followedKeywords.contains { $0.phrase.lowercased() == s.entity.id }
        case .journal: return settings.followedJournals.contains { $0.id == s.entity.id }
        case .researcher: return settings.followedAuthors.contains { $0.id == s.entity.id }
        case .institution: return settings.followedInstitutions.contains { $0.id == s.entity.id }
        case .funder: return settings.followedFunders.contains { $0.id == s.entity.id }
        }
    }

    /// Add what the user chose to their follow lists, where it can be edited like anything
    /// else. One change to the settings, so one refresh.
    func follow(_ chosen: [ProfileSuggestion]) {
        var s = settings
        for item in chosen where !isFollowed(item) {
            switch item.kind {
            case .topic: s.followedTopics.append(item.entity)
            case .keyword: s.addKeyword(item.entity.name)
            case .journal: s.followedJournals.append(item.entity)
            case .researcher: s.followedAuthors.append(item.entity)
            case .institution: s.followedInstitutions.append(item.entity)
            case .funder: s.followedFunders.append(item.entity)
            }
        }
        s.profileFilled = true
        settings = s
    }

    private var followListsAreEmpty: Bool {
        settings.followedTopics.isEmpty && settings.followedJournals.isEmpty && settings.followedAuthors.isEmpty
            && settings.followedInstitutions.isEmpty && settings.followedFunders.isEmpty && settings.followedKeywords.isEmpty
    }

    /// The first time, and only then, fill the empty follow lists from the publications: the
    /// ticked suggestions. After that the lists are the user's; nothing the user removes comes back.
    func fillFromProfileIfNeeded() async {
        guard !filling else { return }
        filling = true
        defer { filling = false }
        let hasSomeone = settings.orcid.flatMap(Orcid.normalised) != nil || !settings.profileOrcids.isEmpty
        guard settings.useMyPublications, !settings.profileFilled, followListsAreEmpty, hasSomeone, canBuild else { return }
        do {
            let found = try await loadProfileSuggestions()
            let chosen = SuggestionKind.allCases.flatMap { found.byKind[$0] ?? [] }.filter(\.selected)
            follow(chosen)
            notice = "Filled what you follow from \(found.paperCount) publications: \(chosen.count) topics, keywords, journals and researchers. They are under Follow and mute in Tune, where you can change them."
        } catch {
            log.error("could not fill the follows from the publications: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Zotero

    /// Check a key with Zotero and keep it. The key and who it belongs to go to the Keychain.
    func connectZotero(key: String) async throws {
        let account = try await ZoteroClient.connect(key: key.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = try? JSONEncoder().encode(account) else { return }
        Keychain.save(String(decoding: data, as: UTF8.self), service: Keychain.zotero)
        zotero = account
        zoteroStatus = nil
        // Pasting a key is asking to use the library.
        settings.useZotero = true
    }

    func disconnectZotero() {
        Keychain.save("", service: Keychain.zotero)
        store.saveZotero(nil)
        zotero = nil
        zoteroStatus = nil
        settings.useZotero = false
    }

    /// The library as profile texts: read again only if Zotero says it changed, and the last copy
    /// stands in when it cannot be reached, so a bad connection never costs the feed its ranking.
    private func zoteroTexts(allowNetwork: Bool) async -> [String] {
        guard settings.useZotero, let account = zotero else { return [] }
        var cache = store.loadZotero()
        if allowNetwork {
            do {
                let fresh = try await ZoteroClient(account: account).recent(limit: settings.zoteroRecent, cache: cache)
                if fresh != cache { store.saveZotero(fresh) }
                cache = fresh
                zoteroStatus = "Read \(min(fresh.items.count, settings.zoteroRecent)) items at \(Date().formatted(date: .omitted, time: .shortened))."
            } catch {
                log.error("zotero read failed: \(String(describing: error), privacy: .public)")
                zoteroStatus = "\(error)" + (cache == nil ? "" : " The last copy is in use.")
                if cache == nil { notice = "Your Zotero library could not be read, so the feed was ranked without it. \(error)" }
            }
        }
        return Zotero.profileTexts(cache?.items ?? [], recent: settings.zoteroRecent)
    }

    // MARK: A library file

    enum ImportProblem: LocalizedError {
        case unreadable, noPapers, projectTooShort
        var errorDescription: String? {
            switch self {
            case .projectTooShort: return "That says too little to tell what the project is about. Paste at least a few sentences of it: the aims, the background or the abstract."
            case .unreadable: return "That file could not be read."
            case .noPapers: return "No papers were found. Paste a RIS or BibTeX export, a list of references, or titles one per line (a bare DOI says nothing about the paper)."
            }
        }
    }

    /// Read an export the user picked and keep it. Importing again later (a newer export) keeps when
    /// each item first appeared, which is how "recently added" is known from files that carry no date.
    /// Returns how many papers it holds and how many of them are new.
    @discardableResult
    func importLibrary(from url: URL) throws -> (total: Int, added: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 200_000_000 else { throw ImportProblem.unreadable }
        let parsed = LibraryImport.items(from: data, filename: url.lastPathComponent)
        guard !parsed.isEmpty else { throw ImportProblem.noPapers }
        let before = Set((libraryFile?.items ?? []).map(\.key))
        let file = LibraryImport.merged(previous: libraryFile, parsed: parsed, name: url.lastPathComponent, now: Date())
        store.saveLibraryFile(file)
        libraryFile = file
        // Importing a file is asking to use it.
        settings.useLibraryFile = true
        return (file.items.count, file.items.filter { !before.contains($0.key) }.count)
    }

    /// Add what the user pasted to the library: RIS or BibTeX, a list of references, or titles one per
    /// line. Each paste counts as added now, so what was pasted last is what counts as newest.
    @discardableResult
    func addPastedReferences(_ text: String) throws -> (total: Int, added: Int) {
        let parsed = LibraryImport.rough(text)
        guard !parsed.isEmpty else { throw ImportProblem.noPapers }
        let before = Set((libraryFile?.items ?? []).map(\.key))
        let file = LibraryImport.adding(to: libraryFile, parsed: parsed, name: "Pasted references", now: Date())
        store.saveLibraryFile(file)
        libraryFile = file
        settings.useLibraryFile = true
        return (file.items.count, file.items.filter { !before.contains($0.key) }.count)
    }

    func removeLibraryFile() {
        store.saveLibraryFile(nil)
        libraryFile = nil
        settings.useLibraryFile = false
    }

    // MARK: A project description

    /// Keep a project the user pasted, in place of any earlier one. It changes what "close to my work"
    /// means, so the feed is ranked again (nothing is fetched again). Throws if it says too little.
    func setProject(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProjectText.wordCount(text) >= ProjectText.fewestWords, !ProjectText.passages(text).isEmpty else {
            throw ImportProblem.projectTooShort
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let file = ProjectFile(name: ProjectText.title(text), text: String(text.prefix(ProjectText.maxCharacters)), addedAt: stamp)
        store.saveProject(file)
        project = file
        needsRefresh = true
    }

    func removeProject() {
        store.saveProject(nil)
        project = nil
        needsRefresh = true
    }

    /// Follow these phrases as keywords, those not followed already, in one change to the settings.
    @discardableResult
    func followKeywords(_ phrases: [String]) -> Int {
        var s = settings
        var added = 0
        for phrase in phrases where !s.followedKeywords.contains(where: { $0.phrase.lowercased() == phrase.lowercased() }) {
            s.addKeyword(phrase)
            added += 1
        }
        if added > 0 { settings = s }
        return added
    }

    private func libraryFileTexts() -> [String] {
        guard settings.useLibraryFile, let file = libraryFile else { return [] }
        return Zotero.profileTexts(file.items, recent: settings.zoteroRecent)
    }

    /// Where in Zotero a saved paper goes (a collection of the library; nil is the top level) and
    /// whether its PDF goes with it. On this device only: like the key, they belong to the account
    /// connected here, and a collection's key means nothing in another library.
    var zoteroCollection: Zotero.Collection? = UserDefaults.standard.data(forKey: "zoteroCollection")
        .flatMap { try? JSONDecoder().decode(Zotero.Collection.self, from: $0) } {
        didSet { UserDefaults.standard.set(zoteroCollection.flatMap { try? JSONEncoder().encode($0) }, forKey: "zoteroCollection") }
    }
    var zoteroAttachPDF: Bool = (UserDefaults.standard.object(forKey: "zoteroAttachPDF") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(zoteroAttachPDF, forKey: "zoteroAttachPDF") }
    }

    /// Add a paper to the user's Zotero library, unless its DOI is already there, in the chosen
    /// collection and with its PDF when one can be had (the kept copy, or a direct download). It is
    /// separate from the reading list: adding to one does not add to the other.
    func addToZotero(_ p: Paper) async {
        await addToZotero(reference: RIS.reference(p), key: p.dedupeKey, link: p.pdfLink.flatMap(URL.init(string:)),
                          referer: p.link, stem: pdfStem(p))
    }

    /// From the reading list, where a paper is only what was kept of it: the feed's full record
    /// where the feed still holds one, else the reference that can be made from what was kept, with
    /// the PDF if it is already on this device.
    func addToZotero(_ s: SavedPaper) async {
        if let known = layout.all.map(\.paper).first(where: { $0.dedupeKey == s.id }) {
            await addToZotero(known)
            return
        }
        let reference = RIS.reference(s)
        await addToZotero(reference: reference, key: s.id, link: nil, referer: s.link,
                          stem: String(RIS.fileName(for: reference).dropLast(4)))
    }

    private func addToZotero(reference: RIS.Reference, key: String, link: URL?, referer: URL?, stem: String) async {
        guard let account = zotero else { return }
        // Said at once, and left up long enough to read: it is the reason nothing arrives in the library.
        guard account.canWrite else { show(ZoteroError.cannotWrite.description, seconds: 15); return }
        let client = ZoteroClient(account: account)
        show("Adding to Zotero…", seconds: 30)
        do {
            if let doi = reference.doi, try await client.has(doi: doi) { show("Already in your Zotero library"); return }
            var pdf: ZoteroClient.PDF?
            if zoteroAttachPDF {
                let file: URL?
                if let link { file = await PDFCache.file(for: key, url: link, referer: referer, stem: stem) }
                else { file = await PDFCache.lookupAnywhere(key) }
                if let file, let md5 = PDFCache.md5(of: file) { pdf = ZoteroClient.PDF(file: file, md5: md5) }
            }
            let added = try await client.add(reference, collection: zoteroCollection?.key, pdf: pdf)
            var text = "Added to Zotero" + (zoteroCollection.map { " in “\($0.name)”" } ?? "")
            switch added.pdf {
            case .attached: text += ", with its PDF"
            case .skipped(let why): text += ". " + why
            case .notOffered: if zoteroAttachPDF && link != nil { text += ". Its PDF could not be fetched, so none was attached." }
            }
            show(text, seconds: 8)
        } catch {
            show("\(error)", seconds: 15)
        }
    }

    /// Say something for a few seconds, over whatever is on screen. Tapping it puts it away.
    func show(_ text: String, seconds: Double = 5) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.toast == text { self?.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    // MARK: After the fact: what the thumbs count for

    /// A thumb was changed from Tune (set to be ignored, taken back): the ranking follows at the next refresh.
    func feedbackChanged() { needsRefresh = true }

    func setIgnored(_ ignored: Bool, id: String, in kind: Feedback.Kind) {
        settings.feedback.setIgnored(ignored, id: id, in: kind)
        feedbackChanged()
    }

    func removeFeedback(id: String, in kind: Feedback.Kind) {
        switch kind {
        case .saved: settings.feedback.saved.removeAll { $0.id == id }
        case .liked: settings.feedback.unlike(id)
        case .hidden: settings.feedback.unhide(id: id)
        }
        feedbackChanged()
    }

    /// The papers in the feed now that are most like what the user put on the reading list or marked
    /// For me, each with the one it is like, worked out here on the device with the same model that ranks.
    func likedInfluence() async -> [Ranker.Influence.Pull] {
        let entries = FeedBuilder.profile(settings, own: [], now: Date())
        let papers = layout.all.map(\.paper)
        let cached = store.loadEmbeddings()
        return await Task.detached(priority: .userInitiated) {
            let embedder = await TextEmbedders.best().map { CachingEmbedder($0, stored: cached) }
            return Ranker.influence(papers, profile: entries, avoid: [], embedder: embedder, limit: 12).pulled
        }.value
    }

    // MARK: What the user does with a paper

    func status(of p: Paper) -> History.Status { history.status(of: p.dedupeKey) }

    /// The time a post was in front of the reader. The layout is not rearranged: that waits for the next
    /// refresh or the next launch, as for seen.
    func addDwell(_ p: Paper, seconds: Double) {
        history.addDwell(p.dedupeKey, seconds: seconds, at: Date())
        saveHistorySoon()
        syncHistorySoon(after: 45)
    }

    func isLiked(_ p: Paper) -> Bool { settings.feedback.isLiked(p) }

    /// "For me": teaches the feed without saving. It also counts the paper as studied, so it leaves the top
    /// at the next refresh. Taking it back removes it from the profile, not from the history.
    func toggleLiked(_ p: Paper) {
        if isLiked(p) {
            settings.feedback.unlike(p.dedupeKey)
            show("Taken back")
        } else {
            settings.feedback.like(p)
            shareKeptPDF(p)
            history.markStudied(p.dedupeKey, studiedAfter: settings.dwellSeconds, at: Date())
            saveHistorySoon()
            syncHistorySoon(after: 8)
            show("Noted: more papers like this. Not added to your reading list.")
        }
    }

    /// Opened the paper or read its abstract in full.
    func markOpened(_ p: Paper) {
        history.markOpened(p, at: Date())
        saveHistoryNow()
        syncHistorySoon(after: 8)
    }

    private func saveHistorySoon() {
        saveHistoryTask?.cancel()
        saveHistoryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.saveHistoryNow()
        }
    }

    func saveHistoryNow() {
        saveHistoryTask?.cancel()
        store.saveHistory(history)
    }

    func isSaved(_ p: Paper) -> Bool { settings.feedback.saved.contains { $0.id == p.dedupeKey } }

    private func pdfStem(_ p: Paper) -> String { String(RIS.fileName(for: RIS.reference(p)).dropLast(4)) }

    /// A paper just saved or marked For me has its PDF put in the shared folder, if the user has one:
    /// the kept copy, or a direct download made now, so the other devices have it without asking.
    private func shareKeptPDF(_ p: Paper) {
        guard PDFFolder.url != nil, let link = p.pdfLink.flatMap(URL.init(string:)) else { return }
        let stem = pdfStem(p)
        Task {
            if let file = await PDFCache.file(for: p.dedupeKey, url: link, referer: p.link, stem: stem) {
                PDFCache.shareWithDevices(file, key: p.dedupeKey, stem: stem)
            }
        }
    }

    func toggleSaved(_ p: Paper) {
        if isSaved(p) { settings.feedback.unsave(p) } else { settings.feedback.save(p); shareKeptPDF(p) }
    }

    func hide(_ p: Paper) {
        // Taken off the list under the reader's nose: the pane moves on to the next paper.
        let wasOpen = readerPaper?.dedupeKey == p.dedupeKey
        let order = wasOpen ? layout.displayOrder(settings: settings) : []
        settings.feedback.hide(p)
        dropExcluded()
        if wasOpen {
            let next = Reader.selection(afterRemoving: p.dedupeKey, from: order)
                .flatMap { key in layout.all.first { $0.paper.dedupeKey == key }?.paper }
            if let next { openInReader(next) } else { readerPaper = nil }
        }
    }

    // MARK: The reader pane

    /// Show a paper in the pane beside the feed. Opening it there is reading it, as opening its
    /// abstract in the post is on a phone.
    func openInReader(_ p: Paper) {
        readerPaper = p
        markOpened(p)
    }

    /// Next or previous paper in the order on screen (the menu commands). Does nothing while the
    /// pane is not on screen, so a paper is never marked read where nobody could see it.
    func stepReader(_ offset: Int) {
        guard readerShown else { return }
        let keys = layout.displayOrder(settings: settings)
        guard let key = Reader.neighbour(of: readerPaper?.dedupeKey, offset: offset, in: keys),
              key != readerPaper?.dedupeKey,
              let next = layout.all.first(where: { $0.paper.dedupeKey == key })?.paper else { return }
        openInReader(next)
        readerScroll = ScrollRequest(key: key)
    }

    /// "Show less from…": mute the paper's journal, an author or a topic. The
    /// feed is fetched again for it later; until then it is only taken off the screen.
    func muteJournal(of p: Paper) {
        guard let id = p.journalID, let name = p.journal,
              !settings.mutedJournals.contains(where: { $0.id == id }) else { return }
        settings.mutedJournals.append(Entity(id: id, name: name))
        dropExcluded()
    }

    func muteAuthor(id: String, name: String) {
        guard !settings.mutedAuthors.contains(where: { $0.id == id }) else { return }
        settings.mutedAuthors.append(Entity(id: id, name: name))
        dropExcluded()
    }

    func muteTopic(id: String, name: String) {
        guard !settings.mutedTopics.contains(where: { $0.id == id }) else { return }
        settings.mutedTopics.append(Entity(id: id, name: name))
        dropExcluded()
    }

    /// Take from the screen whatever the settings now exclude, using the same
    /// rule as a rebuild so the two cannot disagree.
    private func dropExcluded() {
        let settings = self.settings
        func drop(_ a: inout Arranged) {
            func kept(_ r: RankedPaper) -> Bool { !FeedBuilder.keep([r.paper], settings: settings).isEmpty }
            a.fresh.removeAll { !kept($0) }
            a.earlier.removeAll { !kept($0) }
            a.read.removeAll { !kept($0) }
        }
        drop(&layout.feed)
        drop(&layout.citedYou)
        drop(&layout.following)
        drop(&layout.forYou)
        layout.highlights.removeAll { FeedBuilder.keep([$0.ranked.paper], settings: settings).isEmpty }
    }
}
