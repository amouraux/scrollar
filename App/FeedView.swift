import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
            }
            .navigationTitle("Scrollar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isLoading { ProgressView() }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        let layout = model.layout
        let cited = layout.citedYou.fresh + layout.citedYou.earlier
        if !cited.isEmpty {
            SectionTitle(text: "Cited you", systemImage: "quote.bubble")
            ForEach(cited.prefix(10), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
        }

        if !layout.forYou.fresh.isEmpty {
            SectionTitle(text: "For you", systemImage: "sparkles")
            ForEach(layout.forYou.fresh.prefix(150), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
        }

        if !layout.forYou.earlier.isEmpty {
            if layout.forYou.fresh.isEmpty { CaughtUp() }
            SectionTitle(text: "Earlier", systemImage: "clock")
            ForEach(layout.forYou.earlier.prefix(60), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
        }

        if model.settings.showReadPapers, !layout.forYou.read.isEmpty {
            SectionTitle(text: "Read", systemImage: "checkmark.circle")
            ForEach(layout.forYou.read.prefix(60), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
        }

        if layout.isEmpty, !model.isLoading { EmptyFeed() }
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
            Text(model.hasKey
                 ? "Pull down to load papers, or add what you follow in Tune."
                 : "Add your free OpenAlex key in Tune to start.")
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
                    Text("Updated \(updated.formatted(.relative(presentation: .named)))"
                         + (model.usedEmbeddings ? "" : " · matched by words only: this device has no Apple language model"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .loading(let message):
                banner(icon: "arrow.triangle.2.circlepath", tint: .accentColor, text: "Building your feed. \(message)") { EmptyView() }
            case .failed(let message):
                banner(icon: "exclamationmark.triangle", tint: .orange, text: message) {
                    if model.hasKey { Button("Try again") { Task { await model.refresh() } } }
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

/// The post's picture: the journal's name on a colour that is always the same
/// for that journal, so a journal is recognised before it is read. It stands in
/// for a figure, which open data does not give us; a real figure would go here.
struct CoverBanner: View {
    @Environment(\.colorScheme) private var scheme
    let paper: Paper

    var body: some View {
        let spec = Cover.spec(for: paper, byJournal: true)
        // Dark enough that the white label stays readable on every hue.
        let top = scheme == .dark ? 0.45 : 0.56
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hue: spec.hueA, saturation: 0.6, brightness: top),
                         Color(hue: spec.hueB, saturation: 0.6, brightness: top - 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: spec.symbol)
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.28))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.journal ?? paper.topics.first ?? "Unpublished")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if paper.journal != nil, let topic = paper.topics.first {
                    Text(topic).font(.caption).opacity(0.85).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .padding(.trailing, 60)
        }
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// A post in the stream, laid out like one on LinkedIn: who (badges, names,
/// where they work), then what (the whole title and what the paper shows), then
/// a picture of the journal, then buttons to tell the feed what you think.
struct PaperCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @AppStorage("byline") private var bylineRaw = BylineChoice.last.rawValue
    @AppStorage("showCovers") private var showCovers = true
    let ranked: RankedPaper
    @State private var expanded = false
    @State private var seenTimer: Task<Void, Never>?

    private var paper: Paper { ranked.paper }
    private var status: History.Status { model.status(of: paper) }
    private var choice: BylineChoice { BylineChoice(rawValue: bylineRaw) ?? .last }
    private var people: [Byline] { Byline.people(of: paper, choice: choice) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            post
            // Out of the way once the reader is into the abstract.
            if showCovers && !expanded {
                CoverBanner(paper: paper)
            }
            if expanded { details.transition(.opacity) }
            Divider()
            actionBar
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // Dimmed once read, but never while it is open in front of the reader.
        .opacity(status == .read && !expanded ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        // Counts as seen once it has stayed on screen for a second: a card flicked
        // past is not read, and one that scrolls out cancels the wait.
        .onAppear {
            seenTimer = Task {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { model.markSeen(paper) }
            }
        }
        .onDisappear { seenTimer?.cancel() }
        // The on-device model writes the takeaway for a post that stays on screen.
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { await model.writeTakeaway(for: paper) }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        // Opening a paper to its abstract is reading it, for this purpose.
        if expanded { model.markOpened(paper) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            badges
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(people.isEmpty ? (paper.journal ?? "Unknown authors") : people.map(\.name).joined(separator: " & "))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    statusMark
                }
                if let place = Byline.places(people) {
                    Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(metaLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            moreMenu
        }
    }

    /// One badge, or two overlapping for first and last author.
    @ViewBuilder private var badges: some View {
        if people.isEmpty {
            BylineBadge(initials: Byline.initials(paper.journal ?? "?"), hue: Byline.hue(for: paper.journal ?? paper.title))
        } else if people.count == 1 {
            BylineBadge(initials: people[0].initials, hue: people[0].hue)
        } else {
            HStack(spacing: -9) {
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    BylineBadge(initials: person.initials, hue: person.hue, size: 38)
                        .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                }
            }
        }
    }

    @ViewBuilder private var statusMark: some View {
        if status == .new {
            Text("NEW")
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.accentColor, in: Capsule())
                .foregroundStyle(.white)
        } else if status == .read {
            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
    }

    /// The journal is on the picture; here only when it was and what kind of paper.
    private var metaLine: String {
        var parts = [ageLabel(paper.date)]
        if !showCovers, let journal = paper.journal { parts.append(journal) }
        if paper.kind != .research { parts.append(paper.kind.label) }
        return parts.joined(separator: " · ")
    }

    /// Tuning the feed from the post itself: each choice mutes one thing.
    private var moreMenu: some View {
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
        .foregroundStyle(.secondary)
        .accessibilityLabel("Show less of this")
    }

    /// The authors on the badges whose ids can be told for certain. The names and
    /// the ids are filled separately, so they are only trusted where they line up.
    private var mutableAuthors: [(id: String, name: String)] {
        guard paper.authors.count == paper.authorIDs.count else { return [] }
        return people.map { (paper.authorIDs[$0.index], $0.name) }
    }

    // MARK: Post

    /// The whole title, then what the paper shows. A tap opens the abstract.
    private var post: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                Text(paper.title)
                    .font(.body.weight(.semibold))
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
        .accessibilityHint(expanded ? "Hides the abstract" : "Shows the abstract")
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
            if model.takeaway(for: paper)?.writtenByModel == true {
                Label("The sentences above were written on this device by Apple's language model. The abstract is the authors' own.",
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
            barButton("Not for me", "hand.thumbsdown", hint: "Hides this paper for good") {
                withAnimation { model.hide(paper) }
            }
            barButton("Abstract", expanded ? "chevron.up" : "text.alignleft",
                      hint: expanded ? "Hides the abstract" : "Shows the abstract", action: toggle)
            if let url = paper.link {
                barButton("Open", "arrow.up.right.square", hint: "Opens the paper in your browser") {
                    model.markOpened(paper)
                    openURL(url)
                }
                ShareLink(item: url, subject: Text(paper.title)) {
                    barLabel("Share", "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func barButton(_ title: String, _ image: String, hint: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(title, image) }
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
