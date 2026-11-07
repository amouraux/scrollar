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
}

/// The network half: settings in, a ranked feed out. The app and the command
/// line call this one function, so neither can drift from the other.
struct FeedEngine {
    var openAlex: OpenAlexClient
    var pubmed = PubMedClient()
    var embedder: TextEmbedder? = NLTextEmbedder()
    /// Progress and numbers, for the command line; the app can ignore it.
    var log: (String) -> Void = { _ in }

    func build(_ settings: FeedSettings, today: Date = Date()) async throws -> FeedResult {
        let since = Ranker.dayString(today.addingTimeInterval(-Double(settings.daysBack) * 86_400))
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
                var list = try await openAlex.papers(for: step.seed, since: since)
                if step.explicit && !step.seed.citesYou {
                    for i in list.indices { list[i].followed = true }
                }
                found += list
            } catch {
                log("  skipped \(step.seed.reason): \(error)")
            }
        }
        let myID = me?.id
        var papers = Merge.combine(found.filter { p in myID.map { !p.authorIDs.contains($0) } ?? true })
        log("Candidates: \(found.count) results from \(planned.count) seeds → \(papers.count) unique since \(since)  [\(lap())]")

        // 3. PubMed: abstracts and publication types.
        let abstractsBefore = papers.filter { $0.abstract != nil }.count
        papers = await enrich(papers)

        // DOI-only papers with no abstract: look them up, but only those a
        // quick ranking puts near the top, because each lookup is a request.
        let firstPass = Ranker.rank(papers, profileTexts: profileTexts, settings: settings, today: today)
        var wanted: [Paper] = []
        for r in firstPass.prefix(60) {
            let p = r.paper
            if p.abstract == nil && p.pmid == nil && p.doi != nil { wanted.append(p) }
        }
        var matched: [String: String] = [:]
        for p in wanted {
            if let doi = p.doi, let pmid = try? await pubmed.pmid(forDOI: doi) { matched[doi] = pmid }
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
                          usedEmbeddings: embedder != nil)
    }

    /// PubMed is an addition, never a requirement: if it is down the feed still works.
    private func enrich(_ papers: [Paper]) async -> [Paper] {
        let pmids = papers.compactMap(\.pmid)
        guard !pmids.isEmpty else { return papers }
        do {
            return Enrich.apply(try await pubmed.records(pmids: pmids), to: papers)
        } catch {
            log("  PubMed unavailable (\(error)); continuing without it")
            return papers
        }
    }
}
