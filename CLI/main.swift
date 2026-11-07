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
    guard let key = loadKey() else {
        print("No key. Put OPENALEX_API_KEY=… in Secrets.local (see Secrets.example).")
        return
    }

    var engine = FeedEngine(openAlex: OpenAlexClient(apiKey: key), log: { print($0) })
    if CommandLine.arguments.contains("--no-embeddings") { engine.embedder = nil }
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
