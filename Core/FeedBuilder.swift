import Foundation

struct PlannedSeed: Equatable {
    let seed: Seed
    /// The user chose this, as opposed to us inferring it from their own papers.
    let explicit: Bool
}

/// The pure half of building a feed: what to ask for, and what to keep. The
/// network half is FeedEngine.
enum FeedBuilder {
    /// Turn the settings into the queries to run. Only what is listed under Follow is
    /// followed: nothing is inferred behind the user's back. Their own papers shape what
    /// "close to my work" means and can suggest follows (see Profile.swift), and `myWorkIDs`
    /// gives the one seed that is not a follow, "cites my work", which only counts when
    /// `useMyPublications` is on.
    static func seeds(_ s: FeedSettings, myWorkIDs: [String]) -> [PlannedSeed] {
        var planned: [PlannedSeed] = []
        func add(_ seed: Seed, explicit: Bool) {
            // If a followed topic is also one of the user's own, the explicit one wins.
            if let i = planned.firstIndex(where: { $0.seed == seed }) {
                if explicit && !planned[i].explicit { planned[i] = PlannedSeed(seed: seed, explicit: true) }
            } else {
                planned.append(PlannedSeed(seed: seed, explicit: explicit))
            }
        }

        if s.useMyPublications {
            if !myWorkIDs.isEmpty { add(.cites(workIDs: myWorkIDs, label: "Cites your work"), explicit: false) }
        }
        for e in s.followedTopics {
            // A topic taken from a paper's MeSH headings has no OpenAlex id.
            if let seed = Seed.forTopic(e) { add(seed, explicit: true) }
        }
        for e in s.followedJournals { add(.journal(id: e.id, name: e.name), explicit: true) }
        for e in s.followedAuthors { add(.author(id: e.id, name: e.name), explicit: true) }
        for e in s.followedInstitutions { add(.institution(id: e.id, name: e.name), explicit: true) }
        for e in s.followedFunders { add(.funder(id: e.id, name: e.name), explicit: true) }
        for k in s.followedKeywords where !k.phrase.isEmpty { add(k.seed, explicit: true) }
        for p in s.trackedPapers { add(.cites(workIDs: [p.id], label: "Cites: \(p.name)"), explicit: true) }
        return planned
    }

    /// The text that stands for the user's interests: their own papers (if
    /// enabled) and everything they have saved.
    static func profileTexts(_ s: FeedSettings, own: [Paper]) -> [String] {
        var texts = s.useMyPublications ? own.map { $0.title + ". " + ($0.abstract ?? "") } : []
        texts += s.feedback.saved.map { $0.title + ". " + ($0.abstract ?? "") }
        return texts
    }

    /// Drop what the user has asked not to see. Run it after PubMed has filled
    /// abstracts and types, or "require an abstract" and "hide case reports"
    /// would act on papers that were about to be completed.
    static func keep(_ papers: [Paper], settings s: FeedSettings) -> [Paper] {
        let mutedJournals = Set(s.mutedJournals.map { $0.id.lowercased() })
        // A journal muted by typing its name has no id to match, so it matches by name.
        let mutedJournalNames = Set(s.mutedJournals.filter { SourceRouting.isNamed($0.id) }.map { $0.name.lowercased() })
        let mutedAuthors = Set(s.mutedAuthors.map { $0.id.lowercased() })
        let mutedTopics = Set(s.mutedTopics.map { $0.id.lowercased() })
        let mutedWords = s.mutedKeywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        let languages = Set(s.languages.map { $0.lowercased() })
        let hidden = Set(s.feedback.hidden)
        // Rules on one phrase with the same required words share a reason; a paper passes if any
        // of them accepts it, and the rules of a phrase with different words are OR, not AND.
        var rules: [String: [KeywordRule]] = [:]
        for r in s.followedKeywords { rules[r.seed.reason, default: []].append(r) }

        var kept: [Paper] = []
        for var p in papers {
            if hidden.contains(p.dedupeKey) { continue }
            if s.weight(for: p.kind) == .hide { continue }
            if let j = p.journalID?.lowercased(), mutedJournals.contains(j) { continue }
            if let name = p.journal?.lowercased(), mutedJournalNames.contains(name) { continue }
            if p.authorIDs.contains(where: { mutedAuthors.contains($0.lowercased()) }) { continue }
            if p.topicIDs.contains(where: { mutedTopics.contains($0.lowercased()) }) { continue }
            let text = (p.title + " " + (p.abstract ?? "")).lowercased()
            if mutedWords.contains(where: { text.contains($0) }) { continue }
            if s.requireAbstract && p.abstract == nil { continue }
            if s.openAccessOnly && !p.isOpenAccess { continue }
            if !languages.isEmpty, let l = p.language, !languages.contains(l.lowercased()) { continue }

            // A keyword's own conditions apply to what that keyword found. A paper
            // another seed also found does not need to pass them.
            if !p.reasons.isEmpty {
                p.reasons = p.reasons.filter { reason in rules[reason]?.contains { $0.accepts(text) } ?? true }
                if p.reasons.isEmpty { continue }
            }
            kept.append(p)
        }
        return kept
    }
}
