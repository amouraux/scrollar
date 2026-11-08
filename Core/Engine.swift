import Foundation

enum EngineError: Error, CustomStringConvertible {
    case nothingToFollow
    case noSource

    var description: String {
        switch self {
        case .nothingToFollow:
            return "Nothing to build a feed from: add an ORCID, or follow a topic, journal, author or keyword."
        case .noSource:
            return "No source is on: turn on Europe PMC, or OpenAlex with your key, in Tune."
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
    /// nil when there is no key or the user switched it off.
    var openAlex: OpenAlexClient?
    /// nil when the user switched it off.
    var europePMC: EuropePMCClient? = EuropePMCClient()
    var orcid = OrcidClient()
    var pubmed = PubMedClient()
    var embedder: TextEmbedder? = NLTextEmbedder()
    /// Progress and numbers, for the command line; the app can ignore it.
    var log: (String) -> Void = { _ in }

    func build(_ settings: FeedSettings, previous: PreviousFeed? = nil, today: Date = Date()) async throws -> FeedResult {
        guard openAlex != nil || europePMC != nil else { throw EngineError.noSource }
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
        //    OpenAlex knows them best; where it is off or fails, ORCID and Europe PMC do.
        var me: AuthorProfile?
        var own: [Paper] = []
        if settings.useMyPublications, let orcid = settings.orcid, !orcid.isEmpty {
            var done = false
            if let openAlex {
                do {
                    let author = try await openAlex.author(orcid: orcid)
                    me = author
                    own = try await openAlex.works(filter: "author.id:\(author.id)", perPage: 100)
                    let before = own.filter { $0.abstract != nil }.count
                    own = await enrich(own)
                    log("Profile: \(own.count) papers, abstracts \(before) → \(own.filter { $0.abstract != nil }.count) after PubMed  [\(lap())]")
                    done = true
                } catch {
                    if europePMC == nil { throw error }
                    log("OpenAlex could not give the profile (\(error)); using ORCID and Europe PMC")
                }
            }
            if !done, let europePMC {
                (me, own) = try await profileFromOrcid(orcid, europePMC: europePMC)
                log("Profile from ORCID: \(own.count) papers, \(own.filter { $0.abstract != nil }.count) with abstracts  [\(lap())]")
            }
        }
        let profileTexts = FeedBuilder.profileTexts(settings, own: own)

        // 2. One query per seed. A seed that fails (an id that no longer exists) is
        //    reported and skipped; it must not take the rest of the feed with it.
        let planned = FeedBuilder.seeds(settings,
                                        myTopics: me?.topics.map { Entity(id: $0.id, name: $0.name) } ?? [],
                                        myWorkIDs: own.map(\.id))
        guard !planned.isEmpty else { throw EngineError.nothingToFollow }

        var found: [Paper] = []
        let ownPMIDs = own.compactMap(\.pmid)
        let until = Ranker.dayString(today)
        var perSource: [SourceKind: Int] = [:]
        for step in planned {
            let targets = SourceRouting.targets(for: step.seed, openAlex: openAlex != nil,
                                                europePMC: europePMC != nil, hasOwnPMIDs: !ownPMIDs.isEmpty)
            if targets.isEmpty { log("  no source answers \(step.seed.reason)"); continue }
            for target in targets {
                do {
                    var list: [Paper] = []
                    switch target {
                    case .openAlex:
                        guard let openAlex else { continue }
                        list = try await openAlex.papers(for: step.seed, since: since, maxPages: maxPages)
                    case .europePMC:
                        guard let europePMC,
                              let query = EuropePMCQuery.build(step.seed, since: since, until: until, ownPMIDs: ownPMIDs) else { continue }
                        list = try await europePMC.papers(query: query, maxPages: maxPages)
                        for i in list.indices {
                            list[i].reasons = [step.seed.reason]
                            list[i].citesYou = step.seed.citesYou
                        }
                    }
                    for i in list.indices { list[i].sources = [target.rawValue] }
                    if step.explicit && !step.seed.citesYou {
                        for i in list.indices { list[i].followed = true }
                    }
                    perSource[target, default: 0] += list.count
                    found += list
                } catch {
                    complete = false
                    log("  skipped \(step.seed.reason) in \(target.rawValue): \(error)")
                }
            }
        }
        log("Results by source: " + perSource.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))
        let myID = me?.id
        // The user's own papers are not suggestions, whichever source returned them.
        let ownKeys = Set(own.map(\.dedupeKey))
        var fetched = Merge.combine(found.filter { p in
            !ownKeys.contains(p.dedupeKey) && (myID.map { !p.authorIDs.contains($0) } ?? true)
        })
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

        // The journals' two-year mean citedness, for the "prefer high-impact journals"
        // slider and for the figure on a post. A few requests; if they fail the
        // feed simply has no figures this time.
        if let openAlex { papers = await attachImpact(papers, openAlex: openAlex, previous: mode.isIncremental ? previous : nil) }
        // The authors' h-index costs about a request per hundred authors, so it is
        // only fetched when the user has asked for it to count.
        if settings.authorWeight > 0, let openAlex {
            papers = await attachAuthors(papers, openAlex: openAlex, previous: previous)
            log("Authors: h-index for \(papers.filter { $0.firstAuthorH != nil || $0.lastAuthorH != nil }.count) of \(papers.count) papers  [\(lap())]")
        }

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

    /// The user's papers without OpenAlex: ORCID lists them, Europe PMC supplies the
    /// abstracts and MeSH headings. A work Europe PMC does not have still counts by its title.
    private func profileFromOrcid(_ orcid: String, europePMC: EuropePMCClient) async throws -> (AuthorProfile, [Paper]) {
        let name = (try? await self.orcid.name(orcid: orcid)) ?? orcid
        let works = try await self.orcid.works(orcid: orcid)
        let recent = works.sorted { ($0.year ?? 0) > ($1.year ?? 0) }.prefix(100)
        var papers = (try? await europePMC.papers(dois: recent.compactMap(\.doi))) ?? []
        let have = Set(papers.compactMap(\.doi))
        for work in recent where work.doi.map({ !have.contains($0) }) ?? true {
            guard let title = work.title else { continue }
            papers.append(Paper(id: "orcid:\(work.doi ?? title)", doi: work.doi, pmid: work.pmid, title: title,
                                date: "\(work.year ?? 1900)-01-01"))
        }
        var counts: [String: Int] = [:]
        for p in papers { for t in p.topics { counts[t, default: 0] += 1 } }
        let topics = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5).map { (id: "mesh:" + $0.key, name: $0.key, count: $0.value) }
        let profile = AuthorProfile(id: "orcid:" + orcid, name: name, worksCount: works.count, citedByCount: 0, hIndex: nil, topics: topics)
        return (profile, papers)
    }

    /// Journals' figures change slowly, so an incremental refresh reuses the ones it
    /// already has and asks only for journals it has not seen; a full rebuild asks
    /// again for all of them, which keeps them from going stale.
    private func attachImpact(_ papers: [Paper], openAlex: OpenAlexClient, previous: PreviousFeed?) async -> [Paper] {
        var known: [String: Double] = [:]
        for p in previous?.papers ?? [] {
            if let id = p.journalID, let impact = p.journalImpact { known[id] = impact }
        }
        let wanted = Set(papers.filter { !$0.isRepository }.compactMap(\.journalID)).subtracting(known.keys).sorted()
        if !wanted.isEmpty {
            do { known.merge(try await openAlex.journalImpact(ids: wanted)) { _, new in new } }
            catch { log("  journal figures unavailable (\(error)); continuing without them") }
        }
        return papers.map { paper in
            guard !paper.isRepository, let id = paper.journalID, let impact = known[id] else { return paper }
            var p = paper
            p.journalImpact = impact
            return p
        }
    }

    /// An author's h-index moves slowly and a paper leaves the window within weeks,
    /// so figures already on the papers held are reused, whatever the mode.
    private func attachAuthors(_ papers: [Paper], openAlex: OpenAlexClient, previous: PreviousFeed?) async -> [Paper] {
        var known: [String: Int] = [:]
        for p in (previous?.papers ?? []) + papers {
            guard let lead = p.leadAuthorIDs else { continue }
            if let h = p.firstAuthorH { known[lead.first] = h }
            if let h = p.lastAuthorH { known[lead.last] = h }
        }
        var wanted: Set<String> = []
        for p in papers {
            guard let lead = p.leadAuthorIDs else { continue }
            wanted.insert(lead.first)
            wanted.insert(lead.last)
        }
        let missing = wanted.subtracting(known.keys).sorted()
        if !missing.isEmpty {
            log("  authors: asking for \(missing.count) h-indexes")
            do { known.merge(try await openAlex.authorHIndex(ids: missing)) { _, new in new } }
            catch { log("  author figures unavailable (\(error)); continuing with what is known") }
        }
        return papers.map { paper in
            guard let lead = paper.leadAuthorIDs else { return paper }
            var p = paper
            p.firstAuthorH = known[lead.first]
            p.lastAuthorH = known[lead.last]
            return p
        }
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
