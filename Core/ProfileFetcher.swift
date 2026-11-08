import Foundation

/// A person's papers, from OpenAlex where it is on and answers, else from ORCID's list of
/// their works with Europe PMC supplying the rest. The network half of Profile.swift.
enum OrcidProfile {
    /// The papers behind an ORCID iD without OpenAlex: ORCID lists them, Europe PMC supplies the
    /// abstracts and MeSH headings. A work Europe PMC does not have still counts by its title.
    static func papers(orcid: String, europePMC: EuropePMCClient, orcidClient: OrcidClient) async throws -> (AuthorProfile, [Paper]) {
        let name = (try? await orcidClient.name(orcid: orcid)) ?? orcid
        let works = try await orcidClient.works(orcid: orcid)
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

    /// What Europe PMC's records can say to a suggestion: MeSH headings as topics, journals and
    /// authors by name. It has no ids for people and no funders or institutions to offer.
    static func profileWorks(from papers: [Paper], profileName: String) -> [ProfileWork] {
        let me = Entity(id: "name:" + profileName, name: profileName)
        return papers.compactMap { paper in
            guard let year = Int(paper.date.prefix(4)), year > 1900 else { return nil }
            var work = ProfileWork(year: year)
            work.topics = paper.topics.filter { !MeSH.isGeneric($0) }.map { Entity(id: "mesh:" + $0, name: $0) }
            if !paper.isRepository, let journal = paper.journal { work.journal = Entity(id: SourceRouting.namedID(journal), name: journal) }
            if paper.authors.count <= 30 {
                work.people = paper.authors.map { Entity(id: SourceRouting.namedID($0), name: $0) }
                    .filter { !ProfileAnalysis.isSameAuthor($0, me) }
            }
            return work
        }
    }
}

struct ProfileFetcher {
    var openAlex: OpenAlexClient?
    var europePMC: EuropePMCClient?
    var orcidClient = OrcidClient()

    /// The name the iD belongs to, its works reduced to what can be followed, and how large
    /// its journals are (only OpenAlex knows; otherwise empty).
    func works(orcid: String) async throws -> (name: String, works: [ProfileWork], journalSizes: [String: Int]) {
        if let openAlex {
            do {
                let author = try await openAlex.author(orcid: orcid)
                let works = try await openAlex.profileWorks(authorID: author.id)
                let ids = Array(Set(works.compactMap { $0.journal?.id })).sorted()
                // A failed size lookup only means no warnings, not no suggestions.
                let sizes = (try? await openAlex.journalSizes(ids: ids)) ?? [:]
                return (author.name, works, sizes)
            } catch {
                if europePMC == nil { throw error }
            }
        }
        guard let europePMC else { throw EngineError.noSource }
        let (profile, papers) = try await OrcidProfile.papers(orcid: orcid, europePMC: europePMC, orcidClient: orcidClient)
        return (profile.name, OrcidProfile.profileWorks(from: papers, profileName: profile.name), [:])
    }
}
