import Foundation

// What the reader pane shows and when there is room for one. Pure, so the rules can be tested
// without a window.

enum Reader {
    /// The narrowest window that gets a reader column beside the feed. Below it (a phone, a
    /// narrow Mac window, an iPad in a thin split) a tap opens the abstract in the post, as before.
    /// Chosen so a portrait iPad (810 to 834 points) qualifies and an iPad mini (744) does not:
    /// a column of posts needs about 360 points and the reader about 420.
    static let minimumWidth: Double = 780

    static func isWide(width: Double) -> Bool { width >= minimumWidth }

    /// The feed column's width in a window `total` points wide: a third of it, kept within what
    /// a post reads well at, so the reader gets the rest. A post is never wider than the old
    /// single column (700), and not narrower than the banner and buttons can hold.
    static func feedColumnWidth(total: Double) -> Double {
        min(max(total * 0.38, 340), 460)
    }

    /// One author on the pane, with the institution where it is known. The open data lists an
    /// institution only for the first and the last author, so the others carry none.
    struct AuthorLine: Equatable {
        enum Role: Equatable { case first, middle, last }
        var name: String
        var institution: String?
        /// OpenAlex's h-index, fetched only for the first and last author and only when the
        /// user has asked the ranking to use it, so most of the time there is none.
        var hIndex: Int?
        var role: Role
    }

    /// Authors for the pane: all of them up to `limit`; beyond that the first ones, how many are
    /// left out, and the last author, who leads the lab in the life sciences and so is never cut.
    struct AuthorList: Equatable {
        var head: [AuthorLine]
        var omitted: Int
        var tail: AuthorLine?
        var isEmpty: Bool { head.isEmpty && tail == nil }
    }

    static func authors(of paper: Paper, limit: Int = 12) -> AuthorList {
        let names = paper.authors
        func line(_ i: Int) -> AuthorLine {
            let role: AuthorLine.Role = i == 0 ? .first : (i == names.count - 1 ? .last : .middle)
            let place = role == .first ? paper.firstInstitution : role == .last ? paper.lastInstitution : nil
            let h = role == .first ? paper.firstAuthorH : role == .last ? paper.lastAuthorH : nil
            return AuthorLine(name: names[i], institution: place, hIndex: h, role: role)
        }
        let all = names.indices.filter { !names[$0].isEmpty }
        guard all.count > limit, limit >= 2, let lastIndex = all.last else {
            return AuthorList(head: all.map(line), omitted: 0, tail: nil)
        }
        let head = all.prefix(limit - 1)
        return AuthorList(head: head.map(line), omitted: all.count - head.count - 1, tail: line(lastIndex))
    }

    /// The paper to show after the one at `key` has been taken off the list (hidden): the one that
    /// took its place, else the one above it, else none. `keys` is the order on screen before it went.
    static func selection(afterRemoving key: String, from keys: [String]) -> String? {
        guard let i = keys.firstIndex(of: key) else { return nil }
        var rest = keys
        rest.remove(at: i)
        if rest.isEmpty { return nil }
        return rest[min(i, rest.count - 1)]
    }

    /// The paper `offset` places from `key` in the order on screen, for the arrow keys; stays
    /// where it is at either end. With nothing selected, a step down starts at the top.
    static func neighbour(of key: String?, offset: Int, in keys: [String]) -> String? {
        guard !keys.isEmpty else { return nil }
        guard let key, let i = keys.firstIndex(of: key) else { return offset > 0 ? keys.first : keys.last }
        return keys[min(max(i + offset, 0), keys.count - 1)]
    }
}

extension FeedLayout {
    /// Every post in the order the feed draws it, top to bottom, with the same cuts, so the pane's
    /// next and previous follow what the reader sees. `FeedView.content` draws the same sequence;
    /// a test pins the two orders together for the blended feed.
    func displayOrder(settings: FeedSettings) -> [String] {
        var out = highlights.map { $0.ranked.paper.dedupeKey }
        func add(_ list: [RankedPaper]) { out += list.map { $0.paper.dedupeKey } }
        if settings.feedOrder == .blended {
            add(feed.fresh)
            add(older)
            add(feed.earlier)
            if settings.showReadPapers { add(feed.read) }
        } else {
            add(Array((citedYou.fresh + citedYou.earlier).prefix(10)))
            add(Array((following.fresh + following.earlier).prefix(400)))
            add(Array(forYou.fresh.prefix(FeedLayout.freshCap)))
            add(older)
            add(Array(forYou.earlier.prefix(FeedLayout.earlierCap)))
            if settings.showReadPapers { add(Array((following.read + forYou.read).prefix(FeedLayout.readCap))) }
        }
        return out
    }
}
