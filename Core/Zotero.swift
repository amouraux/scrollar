import Foundation

// Zotero, as far as it can be tested without a network: reading what a library holds, choosing what
// stands for the user's interests, and writing the record to save a paper. The requests themselves
// are in `ZoteroClient.swift`.

/// One entry of a reference library, reduced to what is used: from Zotero's API, or from a RIS or
/// BibTeX export of EndNote, Mendeley or any other manager.
struct LibraryItem: Codable, Equatable {
    var key: String
    var title: String
    var abstract: String?
    var doi: String?
    /// ISO 8601, as Zotero writes it ("2026-11-02T09:14:05Z"); it sorts as text.
    var dateAdded: String
    var tags: [String]
    var journal: String?
    var itemType: String
    /// The year (or date) it was published, when the library says. An export carries no date added,
    /// so this is what orders items that arrived together. Optional: a cache written before it still loads.
    var published: String? = nil
}

/// Who the key belongs to and what it may do, read once when it is connected.
struct ZoteroAccount: Codable, Equatable {
    var key: String
    var userID: Int
    var username: String
    var canWrite: Bool
}

enum Zotero {
    /// Things in a library that are not papers.
    static let notPapers: Set<String> = ["attachment", "note", "annotation"]

    /// The items of an `/items` response. A reply that is not a list, or an item with no title, gives
    /// nothing rather than failing the feed.
    static func items(from data: Data) -> [LibraryItem] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let key = entry["key"] as? String, let d = entry["data"] as? [String: Any],
                  let type = d["itemType"] as? String, !notPapers.contains(type),
                  let title = (d["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            func text(_ k: String) -> String? {
                (d[k] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            let tags = ((d["tags"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
            return LibraryItem(key: key, title: title, abstract: text("abstractNote"),
                              doi: Identifiers.doi(text("DOI")), dateAdded: text("dateAdded") ?? "",
                              tags: tags, journal: text("publicationTitle") ?? text("repository") ?? text("proceedingsTitle"),
                              itemType: type, published: text("date").flatMap(LibraryImport.year))
        }
    }

    /// What stands for an item: title, abstract and the user's own tags, which say in their words
    /// what they filed it under. Tags go last, where the embedder (which reads the title and the
    /// last sentences) will see them.
    static func profileText(_ i: LibraryItem) -> String {
        var text = i.title
        if let abstract = i.abstract { text += ". " + abstract }
        let tags = i.tags.filter { !$0.isEmpty }.prefix(8)
        if !tags.isEmpty { text += ". " + tags.joined(separator: ", ") }
        return text
    }

    /// The `recent` most recently added items, as profile texts, newest first. Added, not
    /// modified: an old paper whose note was edited yesterday is not what the user is into now.
    static func profileTexts(_ items: [LibraryItem], recent: Int) -> [String] {
        // Items that arrived together (one import) are ordered by publication year, newest first,
        // and then as they were listed.
        items.enumerated().sorted { a, b in
            if a.element.dateAdded != b.element.dateAdded { return a.element.dateAdded > b.element.dateAdded }
            let (pa, pb) = (a.element.published ?? "", b.element.published ?? "")
            return pa != pb ? pa > pb : a.offset < b.offset
        }.prefix(max(recent, 0)).map { profileText($0.element) }
    }

    /// The account behind a key: `GET /keys/current`.
    static func account(key: String, from data: Data) -> ZoteroAccount? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["userID"] as? Int else { return nil }
        let write = (((o["access"] as? [String: Any])?["user"] as? [String: Any])?["write"] as? Bool) ?? false
        return ZoteroAccount(key: key, userID: id, username: (o["username"] as? String) ?? "", canWrite: write)
    }

    /// The body that saves a paper: a one-element list of Zotero items, which is what `POST /items`
    /// takes. A preprint and a conference paper get their own types, and their venue goes in the
    /// field Zotero keeps it in.
    static func newItems(_ r: RIS.Reference, collection: String? = nil) -> Data {
        let type = r.isPreprint ? "preprint" : r.isConference ? "conferencePaper" : "journalArticle"
        var item: [String: Any] = ["itemType": type, "title": r.title]
        item["creators"] = r.authors.map { name -> [String: String] in
            let parts = RIS.author(name).components(separatedBy: ", ")
            return parts.count >= 2
                ? ["creatorType": "author", "lastName": parts[0], "firstName": parts.dropFirst().joined(separator: ", ")]
                : ["creatorType": "author", "name": name]
        }
        if let abstract = r.abstract { item["abstractNote"] = abstract }
        if let venue = r.journal {
            item[r.isPreprint ? "repository" : r.isConference ? "proceedingsTitle" : "publicationTitle"] = venue
        }
        if !r.date.isEmpty { item["date"] = r.date }
        if let doi = r.doi { item["DOI"] = doi }
        if let url = r.url { item["url"] = url }
        if let language = r.language { item["language"] = language }
        item["tags"] = r.keywords.map { ["tag": $0] }
        if let collection { item["collections"] = [collection] }
        return (try? JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys])) ?? Data()
    }

    /// What a write answered: nil when the item was created, else why not.
    static func writeFailure(from data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Zotero's answer could not be read." }
        if let ok = o["successful"] as? [String: Any], !ok.isEmpty { return nil }
        if let failed = o["failed"] as? [String: Any],
           let first = failed.values.first as? [String: Any], let message = first["message"] as? String { return message }
        return "Zotero did not add it."
    }

    /// The key of the first item a write created.
    static func createdKey(from data: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = o["successful"] as? [String: Any],
              let first = ok.sorted(by: { $0.key < $1.key }).first?.value as? [String: Any] else { return nil }
        return first["key"] as? String
    }

    /// The PDF as a child of the item: stored in Zotero's own file storage, so the reader has it in
    /// the Zotero app. (A link to the publisher's address would cost no storage but is not the file.)
    static func pdfAttachment(parent: String, filename: String) -> Data {
        let item: [String: Any] = ["itemType": "attachment", "parentItem": parent, "linkMode": "imported_file",
                                   "title": "Full text PDF", "contentType": "application/pdf", "filename": filename]
        return (try? JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys])) ?? Data()
    }

    /// What Zotero says to an upload request: either "I already have this file" or where to send it.
    enum UploadAnswer: Equatable {
        case exists
        case send(url: URL, contentType: String, prefix: String, suffix: String, uploadKey: String)
    }

    static func uploadAnswer(from data: Data) -> UploadAnswer? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (o["exists"] as? Int) == 1 { return .exists }
        guard let u = (o["url"] as? String).flatMap(URL.init(string:)), let type = o["contentType"] as? String,
              let prefix = o["prefix"] as? String, let suffix = o["suffix"] as? String,
              let key = o["uploadKey"] as? String else { return nil }
        return .send(url: u, contentType: type, prefix: prefix, suffix: suffix, uploadKey: key)
    }

    struct Collection: Equatable, Hashable, Codable {
        var key: String
        var name: String
    }

    /// The top-level collections of a library, by name. Sub-collections are left out: a picker of a
    /// whole tree is more than saving a paper needs.
    static func collections(from data: Data) -> [Collection] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, let d = row["data"] as? [String: Any],
                  let name = d["name"] as? String, !name.isEmpty else { return nil }
            if let parent = d["parentCollection"] as? String, !parent.isEmpty { return nil }
            return Collection(key: key, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func newCollection(_ name: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: [["name": name]])) ?? Data()
    }
}
