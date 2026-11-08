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
    struct Layout {
        var citedYou = Arranged()
        var forYou = Arranged()
        var isEmpty: Bool { citedYou.isEmpty && forYou.isEmpty }
    }

    var settings: FeedSettings {
        didSet {
            store.saveSettings(settings)
            // Following something new or muting something means fetching again;
            // hiding one paper does not.
            if settings.forRanking != oldValue.forRanking { needsRefresh = true }
            if settings.seenExpiryDays != oldValue.seenExpiryDays { rearrange() }
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
    private(set) var history: History
    private(set) var authorName: String?
    private(set) var updated: Date?
    private(set) var usedEmbeddings = true
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
    private var saveHistoryTask: Task<Void, Never>?
    private let store = Store()

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
        history = store.loadHistory()
        summaries = store.loadSummaries()
        if let cached = store.loadFeed() {
            citedYou = cached.citedYou
            forYou = cached.forYou
            authorName = cached.authorName
            updated = cached.date
            usedEmbeddings = cached.usedEmbeddings ?? true
            builtWith = cached.builtWith
            fetchedThrough = cached.fetchedThrough
            fullBuildAt = cached.fullBuildAt
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
        rearrange()
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

    func refresh(userInitiated: Bool = true) async {
        if isLoading { return }
        let key = effectiveKey
        guard canBuild else {
            phase = .failed("No source is on. Turn on Europe PMC, or add your OpenAlex key, in Tune.")
            return
        }
        phase = .loading("Starting…")
        needsRefresh = false
        let settings = self.settings
        let useOpenAlex = usesOpenAlex
        // What this feed is built for, taken now: the user may change a follow
        // while it runs, and the result must not claim to match that.
        let builtFor = settings.withoutFeedback
        let previous = previousFeed()
        let cachedVectors = store.loadEmbeddings()
        let report: (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.progress(message) }
        }

        do {
            // The ranking is CPU work, so it runs off the main thread.
            let (result, vectors) = try await Task.detached(priority: .userInitiated) { () -> (FeedResult, Data?) in
                let cache = NLTextEmbedder().map { CachingEmbedder($0, stored: cachedVectors) }
                let engine = FeedEngine(openAlex: useOpenAlex ? OpenAlexClient(apiKey: key) : nil,
                                        europePMC: settings.useEuropePMC ? EuropePMCClient() : nil,
                                        embedder: cache, log: report)
                let result = try await engine.build(settings, previous: previous)
                let used = result.profileTexts + (result.citedYou + result.forYou).map { Ranker.text($0.paper) }
                return (result, cache?.snapshot(keeping: used))
            }.value

            phase = .idle
            if let vectors { store.saveEmbeddings(vectors) }
            if userInitiated || layout.isEmpty {
                apply(result, builtFor: builtFor)
            } else {
                stage(result, builtFor: builtFor)
            }
        } catch {
            // Keep showing the last feed; only say what went wrong.
            log.error("refresh failed: \(String(describing: error), privacy: .public)")
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
                            fetchedThrough: through, fullBuildAt: full, builtWith: built)
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

        // Advance what the cache covers only if every seed answered. A fetch with a
        // gap must be asked for again; a full build with a gap cannot be built on at all.
        builtWith = builtFor
        if result.complete {
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
                                  date: Date(), usedEmbeddings: result.usedEmbeddings,
                                  builtWith: builtFor, fetchedThrough: fetchedThrough, fullBuildAt: fullBuildAt))
    }

    /// Keep a refresh aside and count what is new in it, without touching the screen.
    private func stage(_ result: FeedResult, builtFor: FeedSettings) {
        let shown = layout.citedYou.fresh + layout.citedYou.earlier + layout.forYou.fresh + layout.forYou.earlier
        let onScreen = Set(shown.map { $0.paper.dedupeKey })
        let now = Date()
        let incoming = Arranger.arrange(result.citedYou, history: history, settings: settings, now: now).fresh
            + Arranger.arrange(result.forYou, history: history, settings: settings, now: now).fresh
        let count = incoming.filter { !onScreen.contains($0.paper.dedupeKey) }.count
        if count == 0 {
            apply(result, builtFor: builtFor)   // nothing the user would notice changing
        } else {
            pending = result
            pendingBuiltFor = builtFor
            pendingNew = count
        }
    }

    private func rearrange() {
        let now = Date()
        layout = Layout(citedYou: Arranger.arrange(citedYou, history: history, settings: settings, now: now),
                        forYou: Arranger.arrange(forYou, history: history, settings: settings, now: now))
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
              let abstract = p.abstract, Summarizer.isAvailable else { return }
        if let text = await Summarizer.shared.takeaway(title: p.title, abstract: abstract) {
            summaries[key] = text
            saveSummariesSoon()
        } else if !Task.isCancelled {
            summaryFailures.insert(key)   // refused or failed: do not ask again this run
        }
    }

    private func saveSummariesSoon() {
        saveSummariesTask?.cancel()
        saveSummariesTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.store.saveSummaries(self.summaries)
        }
    }

    // MARK: What the user does with a paper

    func status(of p: Paper) -> History.Status { history.status(of: p.dedupeKey) }

    /// Called when a card has been on screen long enough to count as seen. The
    /// layout is deliberately not rearranged: that waits for the next refresh.
    func markSeen(_ p: Paper) {
        history.markSeen(p.dedupeKey, at: Date())
        saveHistorySoon()
    }

    /// Opened the paper or read its abstract in full.
    func markOpened(_ p: Paper) {
        history.markOpened(p, at: Date())
        saveHistoryNow()
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

    func toggleSaved(_ p: Paper) {
        if isSaved(p) { settings.feedback.unsave(p) } else { settings.feedback.save(p) }
    }

    func hide(_ p: Paper) {
        settings.feedback.hide(p)
        dropExcluded()
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
        drop(&layout.citedYou)
        drop(&layout.forYou)
    }
}
