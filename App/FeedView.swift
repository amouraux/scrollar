import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var model

    /// The proportion of the window the feed column takes, as last dragged; 0 is the default.
    @AppStorage("feedColumnFraction") private var storedFraction = 0.0
    /// Where the column was when a drag began, so the drag moves it relative to that.
    @State private var dragStart: Double?

    var body: some View {
        // Wide enough, and the feed becomes a column with the reader beside it. The column stays
        // in the same place in the view tree either way, so resizing a window keeps the scroll position.
        GeometryReader { geo in
            let total = geo.size.width
            let wide = Reader.isWide(width: total)
            let feedWidth = Reader.feedColumnWidth(total: total, fraction: storedFraction)
            HStack(spacing: 0) {
                feedColumn
                    .frame(width: wide ? feedWidth : nil)
                if wide {
                    handle(feedWidth: feedWidth, total: total)
                    ReaderPane()
                }
            }
            .onChange(of: wide, initial: true) { _, now in model.readerShown = now }
            // The answer to Save to Zotero and the like: a post far down the list cannot show it.
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 4, y: 2)
                        .padding(.bottom, 90).padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.default, value: model.toast)
        }
    }

    /// The line between the columns, with a wider strip to grab. Dragging resizes; a double tap
    /// goes back to the default. The width is remembered as a fraction of the window.
    private func handle(feedWidth: Double, total: Double) -> some View {
        Color.clear
            .frame(width: Reader.handleWidth)
            .overlay { Rectangle().fill(Color(.separator)).frame(width: 1) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? feedWidth
                        dragStart = start
                        storedFraction = Reader.fraction(forFeedWidth: start + value.translation.width, total: total)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { storedFraction = 0 }
            .accessibilityElement()
            .accessibilityLabel("Width of the feed and the reader")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 40.0 : -40.0
                storedFraction = Reader.fraction(forFeedWidth: feedWidth + step, total: total)
            }
    }

    private var feedColumn: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Color.clear.frame(height: 0).id("top")
                        StatusBanner()
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(.systemGroupedBackground))
                .refreshable { await model.refresh() }
                .overlay(alignment: .top) {
                    if model.pendingNew > 0 {
                        Button {
                            model.applyPending()
                            withAnimation { proxy.scrollTo("top", anchor: .top) }
                        } label: {
                            Label("\(model.pendingNew) new papers", systemImage: "arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                                .shadow(radius: 4, y: 2)
                        }
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.default, value: model.pendingNew)
                // Stepping with the keyboard brings the paper into view. Centred: with no anchor the
                // scroll view also slid the column sideways to align the post's edge.
                .onChange(of: model.readerScroll) { _, request in
                    if let request { withAnimation { proxy.scrollTo(request.key, anchor: .center) } }
                }
            }
            // No title bar: the stream starts at the top of the screen. Progress is
            // shown by the banner at the head of the list.
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder private var content: some View {
        let layout = model.layout

        // The few that fit particularly well, above everything, each saying why.
        if !layout.highlights.isEmpty {
            SectionTitle(text: "Highlights", systemImage: "star.circle")
            ForEach(layout.highlights, id: \.ranked.paper.dedupeKey) { PaperCard(ranked: $0.ranked, highlight: $0.reason) }
        }

        if model.settings.feedOrder == .blended {
            // One list in the order of its score; the line on each card says why it is there.
            let feed = layout.feed
            if !feed.fresh.isEmpty {
                SectionTitle(text: "Your feed", systemImage: "text.justify.leading")
                ForEach(feed.fresh, id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }
            olderPapers(layout)
            if !feed.earlier.isEmpty {
                if feed.fresh.isEmpty && layout.highlights.isEmpty && layout.older.isEmpty { CaughtUp() }
                SectionTitle(text: "Earlier", systemImage: "clock")
                ForEach(feed.earlier, id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }
            if model.settings.showReadPapers, !feed.read.isEmpty {
                SectionTitle(text: "Read", systemImage: "checkmark.circle")
                ForEach(feed.read, id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }
        } else {
            let cited = layout.citedYou.fresh + layout.citedYou.earlier
            if !cited.isEmpty {
                SectionTitle(text: "Cited you", systemImage: "quote.bubble")
                ForEach(cited.prefix(10), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }

            // Everything something you follow found, newest first, with no cut-off by rank.
            let following = layout.following.fresh + layout.following.earlier
            if !following.isEmpty {
                SectionTitle(text: "From what you follow", systemImage: "star")
                ForEach(following.prefix(400), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }

            if !layout.forYou.fresh.isEmpty {
                SectionTitle(text: "For you", systemImage: "sparkles")
                ForEach(layout.forYou.fresh.prefix(FeedLayout.freshCap), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }

            olderPapers(layout)
            if !layout.forYou.earlier.isEmpty {
                if layout.forYou.fresh.isEmpty && layout.following.fresh.isEmpty && layout.older.isEmpty { CaughtUp() }
                SectionTitle(text: "Earlier", systemImage: "clock")
                ForEach(layout.forYou.earlier.prefix(FeedLayout.earlierCap), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }

            let read = layout.following.read + layout.forYou.read
            if model.settings.showReadPapers, !read.isEmpty {
                SectionTitle(text: "Read", systemImage: "checkmark.circle")
                ForEach(read.prefix(FeedLayout.readCap), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
            }
        }

        if layout.isEmpty, !model.isLoading { EmptyFeed() }
    }

    /// What lies beyond the look-back, then the way to fetch more. The footer is what makes the
    /// feed endless: it asks for older papers when it scrolls into view, and they appear above it.
    @ViewBuilder private func olderPapers(_ layout: FeedLayout) -> some View {
        if !layout.older.isEmpty {
            SectionTitle(text: "Further back", systemImage: "calendar")
            ForEach(layout.older, id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
        }
        if !layout.isEmpty { OlderFooter() }
    }
}

/// Fetches the days before the ones held when it comes into view. A lazy stack only builds it
/// when the reader is near the end, so nothing is fetched for a feed that is still being read.
private struct OlderFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.olderFailed {
                Button { model.retryOlder() } label: {
                    Label("Could not load older papers. Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            } else if model.canLoadOlder {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking further back…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if model.settings.daysBack + model.extraDays >= Incremental.furthestDays {
                Label("That is a year back, as far as it looks", systemImage: "calendar.badge.checkmark")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        // Runs again after each fetch, so a short list keeps going back until the screen is full.
        .task(id: "\(model.extraDays)-\(model.isLoading)") { await model.loadOlder() }
    }
}

private struct SectionTitle: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct CaughtUp: View {
    var body: some View {
        Label("You're up to date", systemImage: "checkmark.seal")
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

private struct EmptyFeed: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "text.magnifyingglass")
        } description: {
            Text(model.canBuild
                 ? "Pull down to load papers, or add what you follow in Tune."
                 : "Turn on a source in Tune to start.")
        }
        .padding(.top, 60)
    }
}

private struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                banner(icon: "info.circle", tint: .blue, text: notice) {
                    Button("Dismiss") { model.notice = nil }
                }
            }
            switch model.phase {
            case .idle:
                if let updated = model.updated {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))"
                             + (model.usedEmbeddings ? "" : " · matched by word counts only: no on-device text model could be loaded"))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #if targetEnvironment(macCatalyst)
                        // No pull-to-refresh with a mouse.
                        Button("Refresh") { Task { await model.refresh() } }.font(.caption)
                        #endif
                    }
                }
            case .loading(let message):
                banner(icon: "arrow.triangle.2.circlepath", tint: .accentColor, text: "Building your feed. \(message)") { EmptyView() }
            case .failed(let message):
                banner(icon: "exclamationmark.triangle", tint: .orange, text: message) {
                    if model.canBuild { Button("Try again") { Task { await model.refresh() } } }
                }
            }
        }
    }

    private func banner<Action: View>(icon: String, tint: Color, text: String,
                                      @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            action().font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The journal's colours and symbol, the same for that journal everywhere: behind the banner of a
/// post and the head of the reader pane. Dark enough for white text in either mode.
struct JournalBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    let paper: Paper

    var body: some View {
        let spec = Cover.spec(for: paper, byJournal: true)
        let top = scheme == .dark ? 0.45 : 0.56
        ZStack {
            LinearGradient(
                colors: [Color(hue: spec.hueA, saturation: 0.6, brightness: top),
                         Color(hue: spec.hueB, saturation: 0.6, brightness: top - 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: spec.symbol)
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.22))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 48)
                .accessibilityHidden(true)
        }
    }
}

/// The round badge at the head of a post: an author's initials. There is no
/// photograph to show (see `Byline`), so the colour does the recognising.
struct BylineBadge: View {
    @Environment(\.colorScheme) private var scheme
    let initials: String
    let hue: Double
    var size: CGFloat = 44

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.55, brightness: scheme == .dark ? 0.50 : 0.58), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A post in the stream, laid out like a headline: the journal and when, the whole title as the
/// biggest thing on it, what the paper shows, who wrote it, why it is here, and buttons to tell
/// the feed what you think.
struct PaperCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @AppStorage("showCovers") private var showCovers = true
    let ranked: RankedPaper
    /// Set for a highlight: why it is one, in words.
    var highlight: String? = nil
    @State private var expanded = false

    private var paper: Paper { ranked.paper }
    /// With the reader pane on screen a tap shows the paper there instead of unfolding the post.
    private var inReader: Bool { model.readerShown }
    private var isSelected: Bool { inReader && model.readerPaper?.dedupeKey == paper.dedupeKey }
    private var status: History.Status { model.status(of: paper) }
    private var choice: BylineChoice { model.settings.byline }
    private var people: [Byline] { Byline.people(of: paper, choice: choice) }

    var body: some View {
        // A compact banner in the journal's colour (its name, its subject, when), then the title as
        // the biggest thing on the card, what the paper shows, who wrote it and why it is here.
        VStack(alignment: .leading, spacing: 0) {
            if showCovers { banner }
            VStack(alignment: .leading, spacing: 10) {
                if !showCovers { eyebrow }
                post
                if !people.isEmpty { byline }
                if let highlight { highlightLine(highlight) }
                if let why = Why.main(for: paper) { whyLine(why) }
                if expanded && !inReader { details.transition(.opacity) }
                Divider()
                actionBar
            }
            .padding(.horizontal, 12)
            .padding(.top, showCovers ? 12 : 10)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: 2.5)
            } else if highlight != nil {
                RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.7), lineWidth: 1.5)
            }
        }
        // Dimmed once read, but never while it is open in front of the reader.
        .opacity(status == .read && !expanded && !isSelected ? 0.6 : 1)
        .id(paper.dedupeKey)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // The time it is in front of the reader is what makes it seen (a flick does not) and,
        // past the user's number of seconds, studied.
        .trackingDwell { model.addDwell(paper, seconds: $0) }
        // The on-device model writes the takeaway for a post that stays on screen.
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { await model.writeTakeaway(for: paper) }
        }
    }

    /// Why this is a highlight: the paper is very close to the user's work and has something more.
    private func highlightLine(_ text: String) -> some View {
        Label(text.prefix(1).uppercased() + text.dropFirst(), systemImage: "star.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .accessibilityLabel("Highlight: \(text)")
    }

    /// Why this post is here, above it as LinkedIn says why it was suggested.
    private func whyLine(_ why: Why) -> some View {
        HStack(spacing: 6) {
            Image(systemName: why.symbol)
            Text(why.text).lineLimit(1)
            if why.others > 0 { Text("+\(why.others)").foregroundStyle(.tertiary) }
        }
        .font(.caption.weight(why.isCitation ? .semibold : .regular))
        .foregroundStyle(why.isCitation ? Color.accentColor : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shown because: \(why.text)")
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        // Opening a paper to its abstract is reading it, for this purpose.
        if expanded { model.markOpened(paper) }
    }

    // MARK: Banner

    /// The journal's own colour, dark enough to read on the card in either mode.
    private var journalColor: Color {
        let hue = Cover.spec(for: paper, byJournal: true).hueA
        return Color(hue: hue, saturation: 0.7, brightness: scheme == .dark ? 0.9 : 0.5)
    }

    /// The journal's name, in full, over a gradient that is the same for that journal everywhere,
    /// with its subject and when under it. It runs to the card's edges, kept low so the title
    /// below is what the eye lands on.
    private var banner: some View {
        return ZStack(alignment: .topLeading) {
            JournalBackdrop(paper: paper)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.journal ?? paper.topics.first ?? "Unpublished")
                        .font(.subheadline.weight(.bold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(bannerSubline)
                        .font(.caption)
                        .opacity(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .padding(.trailing, 56)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.vertical, 9)
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                statusMark(onColor: true)
                moreMenu(tint: .white)
            }
            .padding(.trailing, 4)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
    }

    /// The subject, when, and what kind of paper, under the journal's name.
    private var bannerSubline: String {
        var parts: [String] = []
        if paper.journal != nil, let topic = paper.topics.first { parts.append(topic) }
        parts.append(ageLabel(paper.date))
        if paper.kind != .research { parts.append(paper.kind.label) }
        return parts.joined(separator: " · ")
    }

    /// The same, as a plain line, for when the colour is switched off.
    private var eyebrow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(paper.journal ?? "Unpublished").font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text("· " + bannerSubline).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            statusMark(onColor: false)
            Spacer(minLength: 0)
            moreMenu(tint: .secondary)
        }
        .frame(minHeight: 24)
    }

    // MARK: Byline

    /// Who wrote it, smaller than the title, with where they work and the figures the ranking used.
    private var byline: some View {
        HStack(alignment: .top, spacing: 8) {
            badges
            VStack(alignment: .leading, spacing: 1) {
                Text(people.map(\.name).joined(separator: " & "))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let place = Byline.places(people) {
                    Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let figures = figuresLine {
                    Text(figures).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// One badge, or two overlapping for first and last author.
    @ViewBuilder private var badges: some View {
        if people.count == 1 {
            BylineBadge(initials: people[0].initials, hue: people[0].hue, size: 32)
        } else {
            HStack(spacing: -8) {
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    BylineBadge(initials: person.initials, hue: person.hue, size: 30)
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
            }
        }
    }

    @ViewBuilder private func statusMark(onColor: Bool) -> some View {
        if status == .new {
            Text("NEW")
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(onColor ? Color.white : Color.accentColor, in: Capsule())
                .foregroundStyle(onColor ? journalColor : Color.white)
        } else if status == .read {
            Image(systemName: "checkmark").font(.caption2.weight(.bold))
                .foregroundStyle(onColor ? Color.white.opacity(0.85) : Color.secondary)
        }
    }

    /// The figure the ranking used, shown while the option is on so it can be judged.
    private var hIndexLabel: String? {
        let s = model.settings
        guard s.authorWeight > 0 else { return nil }
        guard let h = Ranker.chosenH(paper, focus: s.byline) else { return nil }
        // Say whose it is when two authors are shown and it is the higher one.
        guard s.byline == .both, let first = paper.firstAuthorH, let last = paper.lastAuthorH, first != last else {
            return "h-index \(h)" + (s.byline == .both ? "" : s.byline == .last ? " (last author)" : " (first author)")
        }
        return "h-index \(h) (\(first > last ? "first" : "last") author)"
    }

    /// The journal's impact and the author's h-index, while the options that use them are on, so
    /// the ranking can be judged.
    private var figuresLine: String? {
        var parts: [String] = []
        if model.settings.impactWeight > 0, let impact = paper.journalImpact { parts.append("Impact " + String(format: "%.1f", impact)) }
        if let h = hIndexLabel { parts.append(h) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tuning the feed from the post itself: each choice mutes one thing.
    private func moreMenu(tint: Color) -> some View {
        Menu {
            if paper.journalID != nil, let name = paper.journal {
                Button("Show less from \(name)", systemImage: "newspaper") { model.muteJournal(of: paper) }
            }
            ForEach(mutableAuthors, id: \.id) { author in
                Button("Show less from \(author.name)", systemImage: "person") {
                    model.muteAuthor(id: author.id, name: author.name)
                }
            }
            if paper.topics.count == paper.topicIDs.count, let topic = paper.topics.first, let id = paper.topicIDs.first {
                Button("Show less about \(topic)", systemImage: "tag") { model.muteTopic(id: id, name: topic) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .foregroundStyle(tint)
        .accessibilityLabel("Show less of this")
    }

    /// The authors on the badges whose ids can be told for certain. The names and
    /// the ids are filled separately, so they are only trusted where they line up.
    private var mutableAuthors: [(id: String, name: String)] {
        guard paper.authors.count == paper.authorIDs.count else { return [] }
        return people.map { (paper.authorIDs[$0.index], $0.name) }
    }

    // MARK: Post

    /// The whole title, the biggest thing on the card, then what the paper shows. A tap opens the abstract.
    private var post: some View {
        Button(action: tapPost) {
            VStack(alignment: .leading, spacing: 6) {
                Text(paper.title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let takeaway = model.takeaway(for: paper) {
                    Text(takeaway.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(inReader ? "Shows the paper beside the feed" : expanded ? "Hides the abstract" : "Shows the abstract")
    }

    private func tapPost() {
        if inReader { model.openInReader(paper) } else { toggle() }
    }

    // MARK: Opened

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !paper.authors.isEmpty {
                Text(authorLine).font(.footnote).foregroundStyle(.secondary)
            }
            if let text = paper.abstract {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("No abstract available.").font(.callout).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if paper.isOpenAccess {
                    Label("Open access", systemImage: "lock.open").font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                }
                Label(paper.reasons.joined(separator: " · "), systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !paper.sourceNames.isEmpty {
                Label("Found in " + paper.sourceNames.joined(separator: " and "), systemImage: "magnifyingglass")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if model.takeaway(for: paper)?.writtenByModel == true {
                Label("The sentences above were \(model.summaryNote). The abstract is the authors' own.",
                      systemImage: "sparkles")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var authorLine: String {
        let names = paper.authors
        if names.count <= 4 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " … " + (names.last ?? "")
    }

    // MARK: Feedback

    private var actionBar: some View {
        HStack(spacing: 0) {
            let saved = model.isSaved(paper)
            barButton(saved ? "Saved" : "Save", saved ? "bookmark.fill" : "bookmark",
                      hint: "Saves it, and finds more like it") {
                model.toggleSaved(paper)
            }
            let liked = model.isLiked(paper)
            barButton("For me", liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                      hint: liked ? "Takes back that this is for you"
                                  : "Tells the feed this is the kind of paper you want, without saving it",
                      tint: liked ? Color.accentColor : nil) {
                model.toggleLiked(paper)
            }
            barButton("Not for me", "hand.thumbsdown", hint: "Hides this paper for good") {
                withAnimation { model.hide(paper) }
            }
            if !inReader {
                barButton("Abstract", expanded ? "chevron.up" : "text.alignleft",
                          hint: expanded ? "Hides the abstract" : "Shows the abstract", action: toggle)
            }
            if let url = paper.link {
                barButton("Open", "arrow.up.right.square", hint: "Opens the paper in your browser") {
                    model.markOpened(paper)
                    openURL(url)
                }
            }
            ShareMenu(paper: paper) { barLabel("Share", "square.and.arrow.up") }
        }
    }

    private func barButton(_ title: String, _ image: String, hint: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(title, image).foregroundStyle(tint ?? .secondary) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
    }

    private func barLabel(_ title: String, _ image: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: image).font(.system(size: 17))
            Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// "3d ago" from a yyyy-MM-dd date.
func ageLabel(_ date: String) -> String {
    guard let days = Ranker.ageInDays(date, today: Date()) else { return date }
    switch Int(days) {
    case ..<1: return "Today"
    case 1: return "Yesterday"
    case 2..<14: return "\(Int(days))d ago"
    case 14..<60: return "\(Int(days) / 7)w ago"
    default: return date
    }
}
