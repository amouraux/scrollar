import SwiftUI

// Searching for a phrase. The sources that are on are asked for the last twelve months, and what comes back is
// ranked the way the feed is: by the phrase first, then by what the user keeps, their library and projects, what
// they searched for lately and the levels they set. A search is remembered on this device and, for a while, counts
// as an interest of its own in the feed, but only when the user agrees after seeing the results, and a search
// that finds nothing is tried again with its misspelled words put right. The rules are in Core/Search.swift
// and Core/Typos.swift.

private struct SearchingKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside the search screen, whose papers are not in the feed and so cannot be shown in the reader pane.
    var inSearch: Bool {
        get { self[SearchingKey.self] }
        set { self[SearchingKey.self] = newValue }
    }
}

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var state: Phase = .idle
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool
    /// Phrases the user has answered the question for in this visit, so it is not asked twice.
    @State private var answered: Set<String> = []

    private enum Phase {
        case idle
        case searching
        case found(AppModel.SearchOutcome)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle: recent
                case .searching:
                    VStack(spacing: 12) { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("The search did not work", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) } actions: {
                        Button("Try again") { run(text) }
                    }
                case .found(let outcome): results(outcome)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .top, spacing: 0) { field }
        }
        .environment(\.inSearch, true)
        .onAppear { focused = true }
        .onDisappear { task?.cancel() }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search papers", text: $text)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { run(text) }
            if !text.isEmpty {
                Button {
                    text = ""
                    task?.cancel()
                    state = .idle
                    focused = true
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    private func run(_ phrase: String) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phrase.count >= 2 else { return }
        text = phrase
        focused = false
        task?.cancel()
        state = .searching
        task = Task {
            do {
                let found = try await model.search(phrase)
                if !Task.isCancelled { state = .found(found) }
            } catch {
                if !Task.isCancelled { state = .failed("\(ErrorText.brief(error))") }
            }
        }
    }

    // MARK: Before a search

    private var recent: some View {
        @Bindable var model = model
        let now = Date()
        return List {
            if !model.searches.isEmpty {
                Section {
                    ForEach(model.searches, id: \.text) { search in
                        Button { run(search.text) } label: {
                            HStack {
                                Label(search.text, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                                Spacer()
                                if model.settings.countsSearches {
                                    Text(Self.standing(SearchLog.weight(search, now: now)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions { Button("Forget", role: .destructive) { model.forgetSearch(search) } }
                    }
                    Button("Forget all", role: .destructive) { model.clearSearches() }
                } header: {
                    Text("Recent searches")
                } footer: {
                    Text(model.settings.countsSearches
                         ? "A recent search pulls the feed toward it, less and less: it counts half as much after two weeks. Swipe left to forget one."
                         : "These do not change the feed. Swipe left to forget one.")
                }
            }
            Section {
                Toggle("Let searches shape the feed", isOn: $model.settings.countsSearches)
                Toggle("Ask me after each search", isOn: $model.settings.asksAboutSearches)
                    .disabled(!model.settings.countsSearches)
            } footer: {
                Text("After a search, you are asked whether it should count toward your feed. Searches you agree to are kept on this device only. They are not synced or backed up, and the phrase is sent to the sources that are on, as a search term, like any keyword you follow.")
            }
        }
    }

    /// How much a search still counts, in words.
    static func standing(_ weight: Double) -> String {
        weight >= 0.75 ? "Counts strongly" : weight >= 0.4 ? "Counts" : "Counts a little"
    }

    // MARK: After

    @ViewBuilder private func results(_ outcome: AppModel.SearchOutcome) -> some View {
        let query = outcome.query
        if outcome.papers.isEmpty {
            ContentUnavailableView {
                Label("Nothing found", systemImage: "magnifyingglass")
            } description: {
                Text("No paper in the last twelve months matches “\(query)”, or what you hid and muted took them all out. Check the spelling, or try other words.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if outcome.corrected {
                        note("No results for “\(outcome.original)”, so these are for “\(query)”.", symbol: "textformat.abc")
                    }
                    if let suggestion = outcome.suggestion {
                        Button { run(suggestion) } label: {
                            HStack {
                                Label("Did you mean “\(suggestion)”?", systemImage: "textformat.abc")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text("Search").font(.subheadline)
                            }
                            .padding(12)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    countQuestion(query)
                    Text("\(outcome.papers.count) \(outcome.papers.count == 1 ? "paper" : "papers") from the last twelve months, ranked by your search first, then by what you keep, your library and projects, and the levels you set.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    ForEach(outcome.papers, id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Whether this search should count toward the feed: asked once the results are on screen, so the user knows
    /// what the search was before agreeing; not asked if they turned searches off, said not to ask, or already agreed.
    @ViewBuilder private func countQuestion(_ query: String) -> some View {
        let key = query.lowercased()
        if model.settings.countsSearches, model.settings.asksAboutSearches, !model.isCounted(query), !answered.contains(key) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Count this search toward your feed?", systemImage: "arrow.up.right.circle")
                    .font(.subheadline.weight(.semibold))
                Text("If you agree, your feed leans toward “\(query)” for a while, and less each week. If not, this stays a one-off search and nothing is kept.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { answered.insert(key); model.countSearch(query) } label: {
                        Text("Yes, count it").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { answered.insert(key) } label: {
                        Text("No, just this once").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        } else if model.isCounted(query) {
            Label("This search counts toward your feed", systemImage: "checkmark.circle")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
