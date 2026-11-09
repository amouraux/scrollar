import Foundation

// Which reference managers the user uses. Each can be reached in a different way, so the screen and the
// Share menu show only what works for the ones in use. None chosen means nothing is hidden.

enum ReferenceManager: String, Codable, CaseIterable {
    case zotero, endnote, mendeley, other

    var title: String {
        switch self {
        case .zotero: return "Zotero"
        case .endnote: return "EndNote"
        case .mendeley: return "Mendeley"
        case .other: return "Papers, Citavi and others"
        }
    }

    /// What can be done with it, in the words the screen uses.
    var abilities: String {
        switch self {
        case .zotero:
            return "Connected directly: it adds a paper with its PDF, in a collection you choose, and learns from your newest items."
        case .endnote:
            return "A .enw file you open (EndNote has no way in from outside), a folder it watches for PDFs, and an export of your library to learn from."
        case .mendeley:
            return "A .ris file, a folder it can watch for PDFs, and an export of your library to learn from. Its own connection needs an app registered with Elsevier, so it is not used."
        case .other:
            return "A .ris file, and an export of your library in RIS or BibTeX to learn from."
        }
    }

    /// Whether it reads a folder for PDFs by itself.
    var watchesAFolder: Bool { self == .endnote || self == .mendeley }
}

extension FeedSettings {
    /// Whether this manager's options are shown: it is in use, or none has been chosen yet.
    func uses(_ manager: ReferenceManager) -> Bool {
        referenceManagers.isEmpty || referenceManagers.contains(manager)
    }

    /// Whether any manager that watches a folder is in use.
    var usesAWatchedFolder: Bool { ReferenceManager.allCases.contains { $0.watchesAFolder && uses($0) } }

    /// Whether an export of a library is useful: for any manager with no connection of its own.
    var usesAnExport: Bool { uses(.endnote) || uses(.mendeley) || uses(.other) }
}

/// Where a chosen folder is, in words, and whether it is in iCloud Drive (which is what makes it reach other devices).
enum FolderPlace {
    static func describe(path: String) -> (text: String, iCloud: Bool) {
        func trail(_ s: Substring) -> String { s.split(separator: "/").joined(separator: " › ") }
        if let r = path.range(of: "/com~apple~CloudDocs/") {
            let rest = trail(path[r.upperBound...])
            return (rest.isEmpty ? "iCloud Drive" : "iCloud Drive › " + rest, true)
        }
        if path.hasSuffix("/com~apple~CloudDocs") { return ("iCloud Drive", true) }
        if let r = path.range(of: "/Mobile Documents/") {
            let rest = path[r.upperBound...].split(separator: "/")
            let container = rest.first.map { String($0).replacingOccurrences(of: "~", with: ".").replacingOccurrences(of: "iCloud.", with: "") } ?? "iCloud"
            return ("iCloud › " + container + (rest.count > 1 ? " › " + trail(path[r.upperBound...].drop(while: { $0 != "/" })) : ""), true)
        }
        let parts = path.split(separator: "/")
        let tail = parts.suffix(2).joined(separator: " › ")
        return ("On this device › " + (tail.isEmpty ? "/" : tail), false)
    }
}
