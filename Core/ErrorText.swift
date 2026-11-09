import Foundation

// What an error looks like on screen. An error printed whole can be a page long: a URLError carries the whole
// address that failed (a Europe PMC query is hundreds of characters) and a dictionary of internals, and a refused
// request can carry a web page. A person needs one short sentence; the full text still goes to the log. Pure and
// tested.

enum ErrorText {
    static let limit = 160

    /// One short sentence for any error.
    static func brief(_ error: Error, limit: Int = ErrorText.limit) -> String {
        let raw: String
        if error is DecodingError {
            raw = "A source sent something the app could not read."
        } else if error is URLError || type(of: error) is NSError.Type {
            // The description alone: not the address, not the internals.
            raw = error.localizedDescription
        } else if let described = (error as Any) as? CustomStringConvertible {
            raw = described.description
        } else {
            raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return clip(raw, limit: limit)
    }

    /// Plain text of at most `limit` characters: tags removed, runs of white space made one space, anything
    /// after Cocoa's "UserInfo=" cut off, and "…" where it was cut.
    static func clip(_ text: String, limit: Int = ErrorText.limit) -> String {
        var t = text
        if let r = t.range(of: "UserInfo=") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > limit else { return t }
        let cut = t.prefix(limit)
        // Not in the middle of a word.
        let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(word).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.-")) + "…"
    }
}
