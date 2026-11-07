import Foundation

enum EngineError: Error, CustomStringConvertible {
    case nothingToFollow

    var description: String {
        switch self {
        case .nothingToFollow:
            return "Nothing to build a feed from: add an ORCID, or follow a topic, journal, author or keyword."
        }
    }
}

struct FeedResult {
    var author: AuthorProfile?
    /// News: new papers citing the user's work or a paper they track.
    var citedYou: [RankedPaper]
    /// Everything else, best first.
    var forYou: [RankedPaper]
    /// The texts the profile was built from, so a cache can keep their vectors.
    var profileTexts: [String]
    /// False when this device has no sentence model (the iOS Simulator does not),
    /// so similarity came from word counts alone. The user is told, not left to guess.
    var usedEmbeddings: Bool
    /// How this feed was fetched, so the app can remember what it covers.
    var mode: Incremental.Mode
    /// Every seed answered. If one failed, the app must not treat this fetch as
    /// covering the period, or what that seed missed would never be asked for again.
    var complete: Bool
    /// When this fetch began: the point the next incremental one can start from.
    var fetchedAt: Date
    /// Papers in the feed that the previous one did not have.
    var newPapers: Int
}

/// The network half: settings in, a ranked feed out. The app and the command
/// line call this one function, so neither can drift from the other.
struct FeedEngine {
    var openAlex: OpenAlexClient
    var pubmed = PubMedClient()
    var embedder: TextEmbedder? = NLTextEmbedder()
    /// Progress and numbers, for the command line; the app can ignore it.
    var log: (String) -> Void = { _ in }

    func build(_ settings: FeedSettings, previous: PreviousFeed? = nil, today: Date = Date()) async throws -> FeedResult {
        let windowStart = Ranker.dayString(today.addingTimeInterval(-Double(settings.daysBack) * 86_400))
        let mode = Incremental.mode(previous: previous, settings: settings, now: today)
        let since: String
        switch mode {
        case .full(let reason):
            since = windowStart
            log("Full build: \(reason)")
        case .incremental(let from):
            since = from
            log("Incremental: asking only for papers published since \(from)")
        }
        // Both modes page the same way. A full build that took only the newest page
        // would cover a few days of a busy topic and call it the whole window, and an
        // incremental one would then find "new" papers that were only never fetched.
        let maxPages = 3
        var complete = true
        var clock = Date()
        func lap() -> String { defer { clock = Date() }; return String(format: "%.1fs", Date().timeIntervalSince(clock)) }

        // 1. The user's own papers: the profile, and the seeds that come from them.
        var me: AuthorProfile?
        var own: [Paper] = []
        if settings.useMyPublications, let orcid = settings.orcid, !orcid.isEmpty {
            let author = try await openAlex.author(orcid: orcid)
            me = author
            own = try await openAlex.works(filter: "author.id:\(author.id)", perPage: 100)
            let before = own.filter { $0.abstract != nil }.count
            own = await enrich(own)
            log("Profile: \(own.count) papers, abstracts \(before) → \(own.filter { $0.abstract != nil }.count) after PubMed  [\(lap())]")
        }
        let profileTexts = FeedBuilder.profileTexts(settings, own: own)

        // 2. One query per seed. A seed that fails (an id that no longer exists) is
        //    reported and skipped; it must not take the rest of the feed with it.
        let planned = FeedBuilder.seeds(settings,
                                        myTopics: me?.topics.map { Entity(id: $0.id, name: $0.name) } ?? [],
                                        myWorkIDs: own.map(\.id))
        guard !planned.isEmpty else { throw EngineError.nothingToFollow }

        var found: [Paper] = []
        for step in planned {
            do {
                var list = try await openAlex.papers(for: step.seed, since: since, maxPages: maxPages)
                if step.explicit && !step.seed.citesYou {
                    for i in list.indices { list[i].followed = true }
                }
                found += list
            } catch {
                complete = false
                log("  skipped \(step.seed.reason): \(error)")
            }
        }
        let myID = me?.id
        var fetched = Merge.combine(found.filter { p in myID.map { !p.authorIDs.contains($0) } ?? true })
        if let previous { fetched = Incremental.carryOver(from: previous.papers, into: fetched) }
        var papers = fetched
        if mode.isIncremental, let previous {
            papers = Incremental.merge(previous: previous.papers, fresh: fetched, windowStart: windowStart)
            log("Candidates: \(found.count) results from \(planned.count) seeds → \(fetched.count) unique; " +
                "with \(previous.papers.count) kept from before, \(papers.count) in the window  [\(lap())]")
        } else {
            log("Candidates: \(found.count) results from \(planned.count) seeds → \(papers.count) unique since \(since)  [\(lap())]")
        }
        let before = Set((previous?.papers ?? []).map(\.dedupeKey))

        // 3. PubMed: abstracts and publication types.
        let abstractsBefore = papers.filter { $0.abstract != nil }.count
        papers = await enrich(papers)

        // DOI-only papers with no abstract: look them up, but only those a
        // quick ranking puts near the top, because each lookup is a request.
        let firstPass = Ranker.rank(papers, profileTexts: profileTexts, settings: settings, today: today)
        var wanted: [Paper] = []
        for r in firstPass.prefix(60) {
            let p = r.paper
            if p.abstract == nil && p.pmid == nil && p.doi != nil && p.notInPubMed != true { wanted.append(p) }
        }
        var matched: [String: String] = [:]
        var missing: Set<String> = []
        for p in wanted {
            guard let doi = p.doi else { continue }
            if let pmid = try? await pubmed.pmid(forDOI: doi) { matched[doi] = pmid } else { missing.insert(doi) }
        }
        if !missing.isEmpty {
            // Not found is an answer: remember it, or the same lookups repeat on every refresh.
            for i in papers.indices where papers[i].doi.map(missing.contains) == true { papers[i].notInPubMed = true }
        }
        if !matched.isEmpty { papers = await enrich(Enrich.attach(pmids: matched, to: papers)) }
        log("PubMed: abstracts \(abstractsBefore) → \(papers.filter { $0.abstract != nil }.count) of \(papers.count); " +
            "\(matched.count) of \(wanted.count) DOI lookups matched  [\(lap())]")

        // 4. Apply the user's mutes and filters before the slow step, so
        //    nothing hidden is ever embedded.
        let kept = FeedBuilder.keep(papers, settings: settings)
        log("Filters: \(papers.count) → \(kept.count) papers")

        // 5. Rank.
        let ranked = Ranker.rank(kept, profileTexts: profileTexts, embedder: embedder, settings: settings, today: today)
        log((embedder == nil ? "Similarity: word counts only" : "Similarity: Apple embeddings + word counts") + "  [\(lap())]")

        return FeedResult(author: me,
                          citedYou: ranked.filter { $0.paper.citesYou },
                          forYou: ranked.filter { !$0.paper.citesYou },
                          profileTexts: profileTexts,
                          usedEmbeddings: embedder != nil,
                          mode: mode,
                          complete: complete,
                          fetchedAt: today,
                          newPapers: ranked.filter { !before.contains($0.paper.dedupeKey) }.count)
    }

    /// PubMed is an addition, never a requirement: if it is down the feed still works.
    /// A paper that already has its publication types was enriched on an earlier
    /// refresh and is not asked for again.
    private func enrich(_ papers: [Paper]) async -> [Paper] {
        let pmids = papers.filter { $0.pubmedTypes.isEmpty }.compactMap(\.pmid)
        guard !pmids.isEmpty else { return papers }
        log("  PubMed: asking for \(pmids.count) records")
        do {
            return Enrich.apply(try await pubmed.records(pmids: pmids), to: papers)
        } catch {
            log("  PubMed unavailable (\(error)); continuing without it")
            return papers
        }
    }
}
