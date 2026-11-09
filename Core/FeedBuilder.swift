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
        // A level the user set overrides the list: below Higher the thing is not searched for at all; at Higher it is
        // searched for but its papers are not kept in full; at Maximum, as before, they are.
        func level(_ kind: FacetKind, _ id: String, _ name: String) -> Level? { s.override(FacetRef(kind: kind, id: id, name: name)) }
        func explicit(_ l: Level?) -> Bool { l == nil || l == .maximum }
        for e in s.followedTopics {
            let l = level(.topic, e.id, e.name)
            if let l, !l.fetches { continue }
            // A topic taken from a paper's MeSH headings has no OpenAlex id.
            if let seed = Seed.forTopic(e) { add(seed, explicit: explicit(l)) }
        }
        for e in s.followedJournals {
            let l = level(.journal, e.id, e.name)
            if let l, !l.fetches { continue }
            add(.journal(id: e.id, name: e.name), explicit: explicit(l))
        }
        for e in s.followedAuthors {
            let l = level(.author, e.id, e.name)
            if let l, !l.fetches { continue }
            add(.author(id: e.id, name: e.name), explicit: explicit(l))
        }
        for e in s.followedInstitutions {
            let l = level(.institution, e.id, e.name)
            if let l, !l.fetches { continue }
            add(.institution(id: e.id, name: e.name), explicit: explicit(l))
        }
        for e in s.followedFunders {
            let l = level(.funder, e.id, e.name)
            if let l, !l.fetches { continue }
            add(.funder(id: e.id, name: e.name), explicit: explicit(l))
        }
        for k in s.followedKeywords where !k.phrase.isEmpty {
            let l = level(.keyword, k.phrase.lowercased(), k.phrase)
            if let l, !l.fetches { continue }
            add(k.seed, explicit: explicit(l))
        }
        // What the user raised that is not in a follow list is searched for too.
        for e in s.levels where e.level.fetches && !s.defaultLevel(e.ref).fetches {
            let seed: Seed?
            switch e.kind {
            case .keyword: seed = .keyword(e.name)
            case .journal: seed = .journal(id: e.id, name: e.name)
            case .author: seed = .author(id: e.id, name: e.name)
            case .topic: seed = Seed.forTopic(Entity(id: e.id, name: e.name))
            case .institution: seed = .institution(id: e.id, name: e.name)
            case .funder: seed = .funder(id: e.id, name: e.name)
            }
            if let seed { add(seed, explicit: e.level.pins) }
        }
        for p in s.trackedPapers { add(.cites(workIDs: [p.id], label: "Cites: \(p.name)"), explicit: true) }
        return planned
    }

    /// The texts that stand for the user's interests: see `profile`, which also says how much each counts.
    /// `project` is the passages of a pasted project description. Having one pasted is the choice, so
    /// there is no switch to read: removing it is how to stop using it.
    static func profileTexts(_ s: FeedSettings, own: [Paper], library: [String] = [], project: [String] = [],
                             now: Date = Date()) -> [String] {
        profile(s, own: own, library: library, project: project, now: now).map(\.text)
    }

    /// Drop what the user has asked not to see. Run it after PubMed has filled
    /// abstracts and types, or "require an abstract" and "hide case reports"
    /// would act on papers that were about to be completed.
    static func keep(_ papers: [Paper], settings s: FeedSettings) -> [Paper] {
        // A mute the user has since given another level is not a mute.
        func muted(_ kind: FacetKind, _ e: Entity) -> Bool {
            let l = s.override(FacetRef(kind: kind, id: e.id, name: e.name))
            return l == nil || l == .hide
        }
        let mutedJournalList = s.mutedJournals.filter { muted(.journal, $0) }
        let mutedJournals = Set(mutedJournalList.map { $0.id.lowercased() })
        // A journal muted by typing its name has no id to match, so it matches by name.
        let mutedJournalNames = Set(mutedJournalList.filter { SourceRouting.isNamed($0.id) }.map { $0.name.lowercased() })
        let mutedAuthors = Set(s.mutedAuthors.filter { muted(.author, $0) }.map { $0.id.lowercased() })
        let mutedTopics = Set(s.mutedTopics.filter { muted(.topic, $0) }.map { $0.id.lowercased() })
        let mutedWords = s.mutedKeywords.filter {
            let l = s.override(.keyword($0)); return l == nil || l == .hide
        }.map { $0.lowercased() }.filter { !$0.isEmpty }
        // And what the user set to Hide is removed like a mute, wherever it came from.
        let hiddenByLevel = s.levels.filter { $0.level == .hide }
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
            if hiddenByLevel.contains(where: { $0.matches(p, text: text) }) { continue }
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
