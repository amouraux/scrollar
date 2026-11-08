import Foundation

/// A person's papers, from OpenAlex where it is on and answers, else from the Europe PMC
/// records that carry their ORCID iD. The network half of Profile.swift.
enum OrcidProfile {
    /// The papers behind an ORCID iD without OpenAlex: Europe PMC's records that carry the iD, with
    /// their abstracts and MeSH headings. Papers where the iD was never linked are missing, so the
    /// profile can be somewhat thinner than OpenAlex's.
    static func papers(orcid: String, europePMC: EuropePMCClient) async throws -> (AuthorProfile, [Paper]) {
        let (name, papers, total) = try await europePMC.papers(orcid: orcid)
        let profile = AuthorProfile(id: "orcid:" + orcid, name: name ?? orcid, worksCount: total, citedByCount: 0, hIndex: nil, topics: [])
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
        let (profile, papers) = try await OrcidProfile.papers(orcid: orcid, europePMC: europePMC)
        return (profile.name, OrcidProfile.profileWorks(from: papers, profileName: profile.name), [:])
    }
}
