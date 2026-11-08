import Foundation

// Prototype driver. Everything that shapes the feed is in the settings file;
// this only loads it, calls FeedEngine and prints. The SwiftUI app will do the
// same with a screen in place of the file.
//
//   ./run.sh <orcid>                          feed for an ORCID, default settings
//   ./run.sh --settings settings.json         feed from a settings file
//   ./run.sh <orcid> --init-settings s.json   write the default settings to edit
//   options: --days N (override)  --top N  --no-embeddings

func loadKey() -> String? {
    if let k = ProcessInfo.processInfo.environment["OPENALEX_API_KEY"], !k.isEmpty { return k }
    guard let text = try? String(contentsOfFile: "Secrets.local", encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("OPENALEX_API_KEY=") {
        return String(line.dropFirst("OPENALEX_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

func value(after name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
}

func show(_ title: String, _ list: ArraySlice<RankedPaper>) {
    print("━━ \(title) ━━\n")
    if list.isEmpty { print("  nothing\n") }
    for (i, r) in list.enumerated() {
        let p = r.paper
        let tag = p.kind == .research ? "" : " [\(p.kind.label)]"
        let venue = p.journal.map { p.isRepository ? "\($0) (repository)" : $0 } ?? "no venue"
        print(String(format: "%2d. %@%@  (score %.2f, fit %.2f)", i + 1, p.title, tag, r.score, r.similarity))
        print("    \(p.date) · \(venue) · \(clip(p.authors.prefix(3).joined(separator: ", "), 60))")
        print("    why: " + p.reasons.joined(separator: " · "))
        if let a = p.abstract { print("    " + clip(a, 200) + (p.abstractFromPubMed ? "  (abstract from PubMed)" : "")) }
        if let l = p.link { print("    \(l.absoluteString)") }
        print("")
    }
}

func run() async throws {
    let args = CommandLine.arguments
    var settings = FeedSettings()
    if let path = value(after: "--settings") {
        // Bad JSON is reported, never replaced by the defaults: the app's lesson
        // from DayHand, where a file that would not load looked exactly like a
        // setting having no effect.
        settings = try FeedSettings.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    }
    if args.count >= 2, !args[1].hasPrefix("--") { settings.orcid = args[1] }
    if let d = value(after: "--days").flatMap(Int.init) { settings.daysBack = max(1, d) }

    if let path = value(after: "--init-settings") {
        try settings.encoded().write(to: URL(fileURLWithPath: path))
        print("Wrote \(path). Edit it, then: ./run.sh --settings \(path)")
        return
    }
    guard settings.orcid != nil || !settings.followedTopics.isEmpty || !settings.followedKeywords.isEmpty
            || !settings.followedJournals.isEmpty || !settings.followedAuthors.isEmpty else {
        print("usage: ./run.sh <orcid> | --settings file.json   (see the header of CLI/main.swift)")
        return
    }
    // --no-openalex and --no-europepmc switch a source off, to try one alone.
    let key = args.contains("--no-openalex") ? nil : loadKey()
    if key == nil && !args.contains("--no-openalex") {
        print("No OpenAlex key (Secrets.local, see Secrets.example): using Europe PMC alone.")
    }
    var engine = FeedEngine(openAlex: key.map { OpenAlexClient(apiKey: $0) },
                            europePMC: args.contains("--no-europepmc") ? nil : EuropePMCClient(),
                            log: { print($0) })
    if CommandLine.arguments.contains("--no-embeddings") { engine.embedder = nil }

    if CommandLine.arguments.contains("--suggest") {
        // What the publications would suggest following, as the Tune sheet shows it:
        // ./run.sh <orcid> --suggest [--also <orcid>]
        let fetcher = ProfileFetcher(openAlex: engine.openAlex, europePMC: engine.europePMC)
        var ids = [settings.orcid].compactMap { $0 }
        var i = 0
        while let n = CommandLine.arguments[i...].firstIndex(of: "--also"), n + 1 < CommandLine.arguments.count {
            ids.append(CommandLine.arguments[n + 1]); i = n + 1
        }
        var sources: [ProfileSourceWorks] = []
        var sizes: [String: Int] = [:]
        for id in ids {
            let (name, works, journalSizes) = try await fetcher.works(orcid: id)
            print("\(name): \(works.count) recent papers")
            sources.append(ProfileSourceWorks(label: name, works: works))
            sizes.merge(journalSizes) { a, _ in a }
        }
        let year = Calendar.current.component(.year, from: Date())
        var found = ProfileAnalysis.suggestions(sources, currentYear: year, journalSizes: sizes)
        if let openAlex = engine.openAlex, let phrases = found[.keyword]?.map(\.entity.name) {
            let monthAgo = Ranker.dayString(Date().addingTimeInterval(-30 * 86_400))
            let volumes = await openAlex.keywordVolumes(phrases: phrases, since: monthAgo)
            found = ProfileAnalysis.suggestions(sources, currentYear: year, journalSizes: sizes, keywordVolumes: volumes)
        }
        for kind in SuggestionKind.allCases {
            print("\n\(kind.title)")
            for s in (found[kind] ?? []).prefix(12) {
                print("  [\(s.selected ? "x" : " ")] \(s.entity.name)  · \(s.count) papers · latest \(s.latestYear)" + (s.note.map { "  ⚠ \($0)" } ?? ""))
            }
        }
        return
    }

    if CommandLine.arguments.contains("--compare") {
        // Full build, then an incremental one as if the last fetch were two days ago.
        // They should give the same feed; the second should be much faster.
        if let base = NLTextEmbedder() { engine.embedder = CachingEmbedder(base) }
        var t = Date()
        let first = try await engine.build(settings)
        let fullTime = Date().timeIntervalSince(t)
        let previous = PreviousFeed(papers: (first.citedYou + first.forYou).map(\.paper),
                                    fetchedThrough: first.fetchedAt.addingTimeInterval(-2 * 86_400),
                                    fullBuildAt: first.fetchedAt.addingTimeInterval(-2 * 86_400),
                                    builtWith: settings.withoutFeedback)
        print("\n--- second build, as if two days later ---")
        t = Date()
        let second = try await engine.build(settings, previous: previous)
        let incrementalTime = Date().timeIntervalSince(t)

        let a = (first.citedYou + first.forYou).map(\.paper.dedupeKey)
        let b = (second.citedYou + second.forYou).map(\.paper.dedupeKey)
        print(String(format: "\nfull: %.1fs, %d papers | incremental: %.1fs, %d papers (%d new)",
                     fullTime, a.count, incrementalTime, b.count, second.newPapers))
        print("same papers in both: \(Set(a) == Set(b)) | same top 10: \(Array(first.forYou.prefix(10).map(\.paper.dedupeKey)) == Array(second.forYou.prefix(10).map(\.paper.dedupeKey)))")
        return
    }

    let result = try await engine.build(settings)

    if let me = result.author {
        print("\n\(me.name) · \(me.worksCount) works · \(me.citedByCount) citations · h-index \(me.hIndex.map(String.init) ?? "?")")
    }
    var kinds: [String: Int] = [:]
    for r in result.citedYou + result.forYou { kinds[r.paper.kind.label, default: 0] += 1 }
    print("Kinds: " + kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n")

    let top = value(after: "--top").flatMap(Int.init) ?? 15
    show("Cited you", result.citedYou.prefix(5))
    show("For you", result.forYou.prefix(top))
}

do {
    try await run()
} catch {
    print("Failed: \(error)")
    exit(1)
}
