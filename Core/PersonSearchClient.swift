import Foundation

/// What a name search came back with.
struct PersonSearchOutcome {
    var candidates: [PersonCandidate]
    /// The sources that answered, by name.
    var asked: [String]
    /// A source that was on and did not answer, in a sentence.
    var problems: [String]
    var verdict: String
}

/// Asks the sources that are on, at the same time, and keeps what the others found when one fails.
/// The only place a person's name leaves the device for this: to Europe PMC and, with the user's own
/// key, OpenAlex. Not tested against the network.
enum PersonSearchClient {
    private typealias Answer = Result<[PersonCandidate], Error>

    static func run(_ name: PersonName, europePMC: EuropePMCClient?, openAlex: OpenAlexClient?) async -> PersonSearchOutcome {
        async let fromOpenAlex = ask(openAlex, name)
        async let fromEuropePMC = ask(europePMC, name)
        var lists: [[PersonCandidate]] = []
        var asked: [String] = []
        var problems: [String] = []
        for (label, answer) in [("OpenAlex", await fromOpenAlex), ("Europe PMC", await fromEuropePMC)] {
            switch answer {
            case nil: continue
            case .success(let found)?: lists.append(found); asked.append(label)
            case .failure(let error)?: problems.append("\(label) could not be asked: \(ErrorText.brief(error))")
            }
        }
        let candidates = PersonSearch.merge(lists)
        var verdict = asked.isEmpty ? "Nothing could be asked, so nobody was found." : PersonSearch.verdict(candidates, asked: asked)
        if openAlex == nil, !asked.isEmpty { verdict += " " + PersonSearch.withoutOpenAlex }
        return PersonSearchOutcome(candidates: candidates, asked: asked, problems: problems, verdict: verdict)
    }

    private static func ask(_ client: OpenAlexClient?, _ name: PersonName) async -> Answer? {
        guard let client else { return nil }
        do { return .success(try await client.people(matching: name)) } catch { return .failure(error) }
    }

    private static func ask(_ client: EuropePMCClient?, _ name: PersonName) async -> Answer? {
        guard let client else { return nil }
        do { return .success(try await client.people(matching: name)) } catch { return .failure(error) }
    }
}
