import Foundation

/// EndNote's own import format (".enw"), the one its apps open directly. RIS also imports, but only
/// through a menu and with a filter the user must choose; this opens with a tap or a double-click.
enum EndNote {
    static func document(_ refs: [RIS.Reference]) -> String {
        refs.map(record).joined(separator: "\n")
    }

    static func record(_ r: RIS.Reference) -> String {
        var lines = ["%0 " + (r.isConference ? "Conference Paper" : "Journal Article")]
        for a in r.authors { lines.append("%A " + clean(RIS.author(a))) }
        lines.append("%T " + clean(r.title))
        if let j = r.journal, !j.isEmpty { lines.append((r.isConference ? "%B " : "%J ") + clean(j)) }
        let parts = r.date.split(separator: "-").map(String.init)
        if let year = parts.first, year.count == 4 { lines.append("%D " + year) }
        if parts.count >= 3, let m = Int(parts[1]), (1...12).contains(m), let d = Int(parts[2]) {
            lines.append("%8 " + months[m - 1] + " \(d)")
        }
        if let doi = r.doi { lines.append("%R " + clean(doi)) }
        if let url = r.url { lines.append("%U " + clean(url)) }
        if let pmid = r.pmid { lines.append("%M " + clean(pmid)) }
        if let language = r.language { lines.append("%G " + clean(language)) }
        for k in r.keywords { lines.append("%K " + clean(k)) }
        if let abstract = r.abstract, !abstract.isEmpty { lines.append("%X " + clean(abstract)) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One field is one line, so a newline inside a value would start a field that is not there.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let months = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]

    /// The file's name: the first author and the year, which is how a reader would look for it.
    static func fileName(for r: RIS.Reference) -> String {
        RIS.fileName(for: r).replacingOccurrences(of: ".ris", with: ".enw")
    }
}
