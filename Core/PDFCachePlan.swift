import Foundation

/// Which downloaded PDFs to delete so the rest fit a size limit. Pure, so the rule is tested
/// without a disk: the files are named and sized by the caller.
enum PDFCachePlan {
    struct Entry: Equatable {
        var name: String
        var size: Int
        /// When it was last shown or saved.
        var used: Date
    }

    static func total(_ entries: [Entry]) -> Int { entries.reduce(0) { $0 + $1.size } }

    /// The names to delete, nothing when the files already fit. The least recently used go first,
    /// and a protected file (the PDF of a paper the user saved) only after every other is gone,
    /// since losing it costs another download of something they chose to keep.
    static func eviction(_ entries: [Entry], limit: Int, protected: Set<String> = []) -> [String] {
        var size = total(entries)
        guard size > limit else { return [] }
        let order = entries.sorted {
            let a = protected.contains($0.name), b = protected.contains($1.name)
            if a != b { return !a }
            return $0.used != $1.used ? $0.used < $1.used : $0.name < $1.name
        }
        var out: [String] = []
        for e in order where size > limit {
            out.append(e.name)
            size -= e.size
        }
        return out
    }

    /// The sizes offered in Tune, in bytes. Nil is no limit.
    static let limits: [(label: String, bytes: Int?)] = [
        ("200 MB", 200_000_000), ("500 MB", 500_000_000), ("1 GB", 1_000_000_000),
        ("2 GB", 2_000_000_000), ("No limit", nil),
    ]
    static let defaultLimit = 500_000_000
}

/// How a PDF is named in the folder shared between devices. The name is for a person browsing it
/// in Files ("Lovelace-2026-Machine-learning-for-sleep"); the tag, a hash of the paper's key that
/// every device computes the same way, is what a device looks the file up by.
enum PDFNames {
    static func fileName(stem: String, tag: String) -> String {
        let clean = stem.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return (clean.isEmpty ? "paper" : String(clean.prefix(80))) + "--" + tag + ".pdf"
    }

    /// iCloud Drive may list a file it has not downloaded as ".name.pdf.icloud".
    static func realName(_ entry: String) -> String {
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud") else { return entry }
        return String(entry.dropFirst().dropLast(".icloud".count))
    }

    static func isFile(_ entry: String, tag: String) -> Bool {
        realName(entry).hasSuffix("--" + tag + ".pdf")
    }
}
