import SwiftUI

// Searching for a phrase. The sources that are on are asked for the last twelve months, and what comes back is
// ranked the way the feed is: by the phrase first, then by what the user keeps, their library and projects, what
// they searched for lately and the levels they set. A search is remembered on this device and, for a while, counts
// as an interest of its own in the feed. The rules are in Core/Search.swift.

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

    private enum Phase {
        case idle
        case searching
        case found(query: String, [RankedPaper])
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
                case .found(let query, let papers): results(query, papers)
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
                if !Task.isCancelled { state = .found(query: phrase, found) }
            } catch {
                if !Task.isCancelled { state = .failed("\(error)") }
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
                Toggle("Let recent searches shape the feed", isOn: $model.settings.countsSearches)
            } footer: {
                Text("Searches are kept on this device only. They are not synced or backed up, and the phrase is sent to the sources that are on, as a search term, like any keyword you follow.")
            }
        }
    }

    /// How much a search still counts, in words.
    static func standing(_ weight: Double) -> String {
        weight >= 0.75 ? "Counts strongly" : weight >= 0.4 ? "Counts" : "Counts a little"
    }

    // MARK: After

    @ViewBuilder private func results(_ query: String, _ papers: [RankedPaper]) -> some View {
        if papers.isEmpty {
            ContentUnavailableView {
                Label("Nothing found", systemImage: "magnifyingglass")
            } description: {
                Text("No paper in the last twelve months matches “\(query)”, or what you hid and muted took them all out. Try other words.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    Text("\(papers.count) papers from the last twelve months, ranked by your search first, then by what you keep, your library and projects, and the levels you set.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 4)
                    ForEach(papers, id: \.paper.dedupeKey) { PaperCard(ranked: $0) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
