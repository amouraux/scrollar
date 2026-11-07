import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    StatusBanner()

                    if !model.citedYou.isEmpty {
                        SectionTitle(text: "Cited you", systemImage: "quote.bubble")
                        ForEach(model.citedYou.prefix(10), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
                    }
                    if !model.forYou.isEmpty {
                        SectionTitle(text: "For you", systemImage: "sparkles")
                        ForEach(model.forYou.prefix(150), id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
                    }
                    if model.citedYou.isEmpty, model.forYou.isEmpty, !model.isLoading {
                        EmptyFeed()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.refresh() }
            .navigationTitle("Scrollar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isLoading { ProgressView() }
                }
            }
        }
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

struct PaperCard: View {
    @Environment(AppModel.self) private var model
    let ranked: RankedPaper
    @State private var expanded = false

    private var paper: Paper { ranked.paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(paper.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            byline
            abstract
            reasons
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if paper.kind != .research {
                Text(paper.kind.label.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            if paper.isOpenAccess {
                Label("Open access", systemImage: "lock.open")
                    .font(.caption2).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Text(ageLabel(paper.date)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var byline: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let journal = paper.journal {
                Text(journal).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            if !paper.authors.isEmpty {
                Text(authorLine).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var authorLine: String {
        let names = paper.authors
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " … " + (names.last ?? "")
    }

    @ViewBuilder private var abstract: some View {
        if let text = paper.abstract {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                if text.count > 320 {
                    Button(expanded ? "Show less" : "Read more") { withAnimation { expanded.toggle() } }
                        .font(.footnote.weight(.semibold))
                }
            }
        } else {
            Text("No abstract available.").font(.callout).foregroundStyle(.tertiary)
        }
    }

    private var reasons: some View {
        Label(paper.reasons.joined(separator: " · "), systemImage: "arrow.turn.down.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var actions: some View {
        HStack(spacing: 22) {
            Button {
                model.toggleSaved(paper)
            } label: {
                Image(systemName: model.isSaved(paper) ? "bookmark.fill" : "bookmark")
            }
            .accessibilityLabel(model.isSaved(paper) ? "Remove from saved" : "Save")

            if let url = paper.link {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .accessibilityLabel("Open paper")
                ShareLink(item: url, subject: Text(paper.title)) { Image(systemName: "square.and.arrow.up") }
            }
            Spacer()
            Button {
                withAnimation { model.hide(paper) }
            } label: {
                Image(systemName: "eye.slash")
            }
            .accessibilityLabel("Hide, don't show this again")
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.top, 2)
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
