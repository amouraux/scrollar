import Foundation

/// Everything the user tells the app becomes a seed, and a seed becomes one
/// saved query. The feed is the merged, ranked result of all of them.
enum Seed: Hashable {
    case topic(id: String, name: String)
    case journal(id: String, name: String)
    case author(id: String, name: String)
    case institution(id: String, name: String)
    case funder(id: String, name: String)
    case keyword(String)
    /// A MeSH heading, for sources that index by it (Europe PMC). Used for the
    /// topics of the user's own papers when OpenAlex, which names topics its own way, is off.
    case mesh(String)
    /// New papers that cite any of these works (at most 100: an OpenAlex limit).
    /// `label` is what the card says: "Cites your work", or the tracked paper's title.
    case cites(workIDs: [String], label: String)

    /// Shown on the card, so the user can see which seed caused it and remove it.
    var reason: String {
        switch self {
        case .topic(_, let name): return "Topic: \(name)"
        case .journal(_, let name): return "Journal: \(name)"
        case .author(_, let name): return "Author: \(name)"
        case .institution(_, let name): return "Institution: \(name)"
        case .funder(_, let name): return "Funder: \(name)"
        case .keyword(let k): return "Keyword: \(k)"
        case .mesh(let name): return "Topic: \(name)"
        case .cites(_, let label): return label
        }
    }

    var citesYou: Bool {
        if case .cites = self { return true }
        return false
    }

    /// OpenAlex `filter=` value for papers published on or after `since`.
    func filter(since: String) -> String {
        let base: String
        switch self {
        case .topic(let id, _): base = "topics.id:\(id)"
        case .journal(let id, _): base = "primary_location.source.id:\(id)"
        case .author(let id, _): base = "author.id:\(id)"
        // The filter keys OpenAlex's own autocomplete recommends. `grants.funder` is
        // not a valid field at all (checked against the API, not assumed), and
        // `lineage` also covers an institution's departments and hospitals.
        case .institution(let id, _): base = "authorships.institutions.lineage:\(id)"
        case .funder(let id, _): base = "awards.funder_id:\(id)"
        // A comma would end the filter value early.
        case .keyword(let k): base = "title_and_abstract.search:" + k.replacingOccurrences(of: ",", with: " ")
        case .mesh(let name): base = "title_and_abstract.search:" + name.replacingOccurrences(of: ",", with: " ")
        case .cites(let ids, _): base = "cites:" + ids.prefix(100).joined(separator: "|")
        }
        return "\(base),from_publication_date:\(since)"
    }
}
