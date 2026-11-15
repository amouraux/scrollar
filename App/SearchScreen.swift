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
    @State private var keepProblem: String?

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
        return List {
            if !model.searches.isEmpty {
                Section {
                    ForEach(model.searches, id: \.text) { search in
                        Button { run(search.text) } label: {
                            HStack {
                                Label(search.text, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                                Spacer()
                                if model.isSearchInterest(search.text) {
                                    Text("Current interest").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions { Button("Forget", role: .destructive) { model.forgetSearch(search) } }
                    }
                    Button("Forget all", role: .destructive) { model.clearSearches() }
                } header: {
                    Text("Recent searches")
                } footer: {
                    Text("Tap one to search again; swipe left to forget it. A recent search does not change the feed by itself: one you added to current interests does, under Tune, Current interests.")
                }
            }
            Section {
                Toggle("Let searches shape the feed", isOn: $model.settings.countsSearches)
                Toggle("Ask me after each search", isOn: $model.settings.asksAboutSearches)
                    .disabled(!model.settings.countsSearches)
            } footer: {
                Text(model.settings.asksAboutSearches
                     ? "After a search, you are asked whether to add it to current interests, follow it as a keyword, or leave it as a one-off. Recent searches and current interests are kept on this device only, not synced or backed up; the phrase goes to the sources that are on, as a search term, like any keyword you follow."
                     : "Each search that finds papers is added to current interests, for two weeks. Recent searches and current interests are kept on this device only, not synced or backed up; the phrase goes to the sources that are on, as a search term, like any keyword you follow.")
            }
        }
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
                    keepQuestion(outcome)
                    Text("\(outcome.papers.count) \(outcome.papers.count == 1 ? "paper" : "papers") from the last twelve months, ranked by your search first, then by what you keep, your library and current interests, and the levels you set.")
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

    /// What to do with this search: asked once the results are on screen, so the user knows what the search finds
    /// before choosing; not asked if they turned searches off, said not to ask, or already chose.
    @ViewBuilder private func keepQuestion(_ outcome: AppModel.SearchOutcome) -> some View {
        let query = outcome.query
        let key = query.lowercased()
        if model.isSearchInterest(query) {
            settled("This search is one of your current interests", symbol: "lightbulb")
        } else if model.isFollowedKeyword(query) {
            settled("You follow this as a keyword", symbol: "checkmark.circle")
        } else if model.settings.countsSearches, model.settings.asksAboutSearches, !answered.contains(key) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keep this search?", systemImage: "arrow.up.right.circle")
                    .font(.subheadline.weight(.semibold))
                Text("As a current interest, the feed searches for “\(query)” and leans toward what it finds, for two weeks; you can change that, or turn it off, under Tune, Current interests. As a keyword you follow, everything it finds is kept in full.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    do { try model.addSearchInterest(query, found: outcome.papers); keepProblem = nil; answered.insert(key) }
                    catch { keepProblem = error.localizedDescription }
                } label: {
                    Text("Add to current interests").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 10) {
                    Button { answered.insert(key); model.followKeywords([query], origin: .search) } label: {
                        Text("Follow as a keyword").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { answered.insert(key) } label: {
                        Text("Just this once").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let keepProblem { Text(keepProblem).font(.footnote).foregroundStyle(.red) }
                if let notice = model.interestNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func settled(_ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: symbol)
            if let notice = model.interestNotice { Text(notice) }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
