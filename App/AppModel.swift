import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case failed(String)
    }

    var settings: FeedSettings {
        didSet {
            store.saveSettings(settings)
            // Following something new or muting something means fetching again;
            // hiding one paper does not.
            if settings.withoutFeedback != oldValue.withoutFeedback { needsRefresh = true }
        }
    }

    var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            Keychain.save(apiKey)
            if oldValue.isEmpty { needsRefresh = true }
        }
    }

    private(set) var citedYou: [RankedPaper] = []
    private(set) var forYou: [RankedPaper] = []
    private(set) var authorName: String?
    private(set) var updated: Date?
    private(set) var usedEmbeddings = true
    private(set) var phase: Phase = .idle
    /// Something the user should be told once, such as a settings file that would not load.
    var notice: String?
    var needsRefresh = false

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
        if let cached = store.loadFeed() {
            citedYou = cached.citedYou
            forYou = cached.forYou
            authorName = cached.authorName
            updated = cached.date
            usedEmbeddings = cached.usedEmbeddings ?? true
            // A follow added just before the app was closed must not wait six hours.
            if let built = cached.builtWith, built != settings.withoutFeedback { needsRefresh = true }
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

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var openAlex: OpenAlexClient { OpenAlexClient(apiKey: effectiveKey) }

    // MARK: Feed

    /// Open the app: show what is cached, and fetch only if it is old or the
    /// settings changed since.
    func refreshIfStale() async {
        guard hasKey else { return }
        let stale = updated.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        if stale || needsRefresh { await refresh() }
    }

    func refresh() async {
        if isLoading { return }
        let key = effectiveKey
        guard !key.isEmpty else {
            phase = .failed("Add your free OpenAlex key in Settings to load papers.")
            return
        }
        phase = .loading("Starting…")
        needsRefresh = false
        let settings = self.settings
        let cachedVectors = store.loadEmbeddings()
        let report: (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.progress(message) }
        }

        do {
            // The ranking is CPU work, so it runs off the main thread.
            let (result, vectors) = try await Task.detached(priority: .userInitiated) { () -> (FeedResult, Data?) in
                let cache = NLTextEmbedder().map { CachingEmbedder($0, stored: cachedVectors) }
                let engine = FeedEngine(openAlex: OpenAlexClient(apiKey: key), embedder: cache, log: report)
                let result = try await engine.build(settings)
                let used = result.profileTexts + (result.citedYou + result.forYou).map { Ranker.text($0.paper) }
                return (result, cache?.snapshot(keeping: used))
            }.value

            citedYou = result.citedYou
            forYou = result.forYou
            authorName = result.author?.name
            updated = Date()
            usedEmbeddings = result.usedEmbeddings
            phase = .idle
            store.saveFeed(CachedFeed(citedYou: citedYou, forYou: forYou, authorName: authorName,
                                      date: Date(), usedEmbeddings: result.usedEmbeddings,
                                      builtWith: settings.withoutFeedback))
            if let vectors { store.saveEmbeddings(vectors) }
        } catch {
            // Keep showing the last feed; only say what went wrong.
            phase = .failed("\(error)")
        }
    }

    private func progress(_ message: String) {
        if case .loading = phase { phase = .loading(message) }
    }

    // MARK: What the user does with a paper

    func isSaved(_ p: Paper) -> Bool { settings.feedback.saved.contains { $0.id == p.dedupeKey } }

    func toggleSaved(_ p: Paper) {
        if isSaved(p) { settings.feedback.unsave(p) } else { settings.feedback.save(p) }
    }

    func hide(_ p: Paper) {
        settings.feedback.hide(p)
        citedYou.removeAll { $0.paper.dedupeKey == p.dedupeKey }
        forYou.removeAll { $0.paper.dedupeKey == p.dedupeKey }
    }
}
