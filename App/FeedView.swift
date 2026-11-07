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

/// A small picture made from the paper's topic: always there, offline, and nobody's figure.
struct CoverView: View {
    @Environment(\.colorScheme) private var scheme
    let paper: Paper
    var size: CGFloat = 56

    var body: some View {
        let spec = Cover.spec(for: paper)
        let brightness = scheme == .dark ? 0.50 : 0.88
        ZStack {
            LinearGradient(
                colors: [Color(hue: spec.hueA, saturation: 0.55, brightness: brightness),
                         Color(hue: spec.hueB, saturation: 0.55, brightness: brightness - 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: spec.symbol)
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

/// A row in the stream: thumbnail, title, where and when, and one sentence. A tap
/// opens it to the full abstract and the actions, so the stream itself stays dense
/// enough to skim several papers to a screen.
struct PaperCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let ranked: RankedPaper
    @State private var expanded = false
    @State private var seenTimer: Task<Void, Never>?

    private var paper: Paper { ranked.paper }
    private var status: History.Status { model.status(of: paper) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: toggle) { row }
                    .buttonStyle(.plain)
                    .accessibilityHint(expanded ? "Hides the abstract" : "Shows the abstract")
                Button {
                    model.toggleSaved(paper)
                } label: {
                    Image(systemName: model.isSaved(paper) ? "bookmark.fill" : "bookmark")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.isSaved(paper) ? "Remove from saved" : "Save")
            }
            if expanded { details.padding(.top, 10).transition(.opacity) }
        }
        .padding(12)
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
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        // Opening a paper to its abstract is reading it, for this purpose.
        if expanded { model.markOpened(paper) }
    }

    // MARK: Collapsed

    private var row: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverView(paper: paper)
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                meta
                if !expanded, let line = Summary.sentence(from: paper.abstract, maxLength: 150) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if status == .new {
                Text("NEW")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            if status == .read {
                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            Text(metaLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let journal = paper.journal { parts.append(journal) }
        parts.append(ageLabel(paper.date))
        if paper.kind != .research { parts.append(paper.kind.label) }
        return parts.joined(separator: " · ")
    }

    // MARK: Expanded

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
            actions
        }
    }

    private var authorLine: String {
        let names = paper.authors
        if names.count <= 4 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " … " + (names.last ?? "")
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let url = paper.link {
                Button {
                    model.markOpened(paper)
                    openURL(url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                ShareLink(item: url, subject: Text(paper.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Spacer()
            Button(role: .destructive) {
                withAnimation { model.hide(paper) }
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .accessibilityLabel("Hide, don't show this again")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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
