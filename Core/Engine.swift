import Foundation

enum EngineError: Error, CustomStringConvertible {
    case nothingToFollow
    case noSource
    case nothingOlder

    var description: String {
        switch self {
        case .nothingToFollow:
            return "Nothing to build a feed from: add an ORCID, or follow a topic, journal, author or keyword."
        case .noSource:
            return "No source is on: turn on Europe PMC, or OpenAlex with your key, in Tune."
        case .nothingOlder:
            return "There is nothing older to ask for."
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
    /// Days held beyond the look-back (see `Incremental.olderStep`).
    var extraDays = 0
}

/// The network half: settings in, a ranked feed out. The app and the command
/// line call this one function, so neither can drift from the other.
struct FeedEngine {
    /// nil when there is no key or the user switched it off.
    var openAlex: OpenAlexClient?
    /// nil when the user switched it off.
    var europePMC: EuropePMCClient? = EuropePMCClient()
    var pubmed = PubMedClient()
    var embedder: TextEmbedder? = NLTextEmbedder()
    /// Progress and numbers, for the command line; the app can ignore it.
    var log: (String) -> Void = { _ in }

    /// `older` asks for the days before the ones held and adds them to `previous`, instead of
    /// refreshing the recent ones.
    func build(_ settings: FeedSettings, previous: PreviousFeed? = nil, today: Date = Date(), older: Bool = false) async throws -> FeedResult {
        guard openAlex != nil || europePMC != nil else { throw EngineError.noSource }
        // What is held reaches back past the look-back when the reader has scrolled to the end.
        let heldExtra = previous?.extraDays ?? 0
        let windowStart = Ranker.dayString(today.addingTimeInterval(-Double(settings.daysBack + heldExtra) * 86_400))
        var extraDays = 0
        let mode: Incremental.Mode
        var untilOverride: String?
        if older {
            guard let previous, let range = Incremental.olderRange(now: today, daysBack: settings.daysBack, extraDays: previous.extraDays)
            else { throw EngineError.nothingOlder }
            mode = .older(since: range.since, until: range.until)
            untilOverride = range.until
            extraDays = range.extraDays
        } else {
            mode = Incremental.mode(previous: previous, settings: settings, now: today)
            extraDays = mode.isIncremental ? heldExtra : 0
        }
        let since: String
        switch mode {
        case .full(let reason):
            since = Ranker.dayString(today.addingTimeInterval(-Double(settings.daysBack) * 86_400))
            log("Full build: \(reason)")
        case .incremental(let from):
            since = from
            log("Incremental: asking only for papers published since \(from)")
        case .older(let from, let to):
            since = from
            log("Older: asking for papers published \(from) to \(to)")
        }
        // Journal and author figures already held are reused, both when refreshing and when going back.
        let reusesPrevious = mode.isIncremental || untilOverride != nil
        // Both modes page the same way. A full build that took only the newest page
        // would cover a few days of a busy topic and call it the whole window, and an
        // incremental one would then find "new" papers that were only never fetched.
        let maxPages = 3
        var complete = true
        var clock = Date()
        func lap() -> String { defer { clock = Date() }; return String(format: "%.1fs", Date().timeIntervalSince(clock)) }

        // 1. The user's own papers, and those of anyone they added to learn from: the profile.
        //    OpenAlex knows them best; where it is off or fails, Europe PMC's records that carry the iD do.
        var me: AuthorProfile?
        var own: [Paper] = []
        var others: [Paper] = []
        if settings.useMyPublications {
            if let orcid = settings.orcid, !orcid.isEmpty {
                (me, own) = try await loadProfile(orcid: orcid)
                log("Profile: \(own.count) papers, \(own.filter { $0.abstract != nil }.count) with abstracts  [\(lap())]")
            }
            // A failure for someone else must not stop the feed: it only means less to learn from.
            for source in settings.profileOrcids {
                do {
                    let (person, papers) = try await loadProfile(orcid: source.orcid)
                    others += papers
                    log("Also learning from \(source.label.isEmpty ? person.name : source.label): \(papers.count) papers")
                } catch {
                    complete = false
                    log("  could not read \(source.orcid): \(error)")
                }
            }
        }
        let profileTexts = FeedBuilder.profileTexts(settings, own: own + others)

        // 2. One query per seed. A seed that fails (an id that no longer exists) is
        //    reported and skipped; it must not take the rest of the feed with it.
        let planned = FeedBuilder.seeds(settings, myWorkIDs: own.map(\.id))
        guard !planned.isEmpty else { throw EngineError.nothingToFollow }

        var found: [Paper] = []
        let ownPMIDs = own.compactMap(\.pmid)
        let until = untilOverride ?? Ranker.dayString(today)
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
                        list = try await openAlex.papers(for: step.seed, since: since, until: untilOverride, maxPages: maxPages)
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
        if let previous, untilOverride != nil {
            // Going back adds to everything held; nothing is dropped for being old.
            papers = Merge.combine(fetched + previous.papers)
            log("Older: \(found.count) results → \(fetched.count) unique; \(papers.count) held now  [\(lap())]")
        } else if mode.isIncremental, let previous {
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
        if let openAlex { papers = await attachImpact(papers, openAlex: openAlex, previous: reusesPrevious ? previous : nil) }
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
                          newPapers: ranked.filter { !before.contains($0.paper.dedupeKey) }.count,
                          // A seed that failed leaves a gap in what was just fetched: ask for it again.
                          extraDays: older && !complete ? heldExtra : extraDays)
    }

    /// One person's papers: OpenAlex when it is on and answers, else the Europe PMC records that
    /// carry their ORCID iD.
    private func loadProfile(orcid: String) async throws -> (AuthorProfile, [Paper]) {
        if let openAlex {
            do {
                let author = try await openAlex.author(orcid: orcid)
                var papers = try await openAlex.works(filter: "author.id:\(author.id)", perPage: 100)
                papers = await enrich(papers)
                return (author, papers)
            } catch {
                if europePMC == nil { throw error }
                log("OpenAlex could not give the profile (\(error)); using Europe PMC")
            }
        }
        guard let europePMC else { throw EngineError.noSource }
        return try await OrcidProfile.papers(orcid: orcid, europePMC: europePMC)
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
