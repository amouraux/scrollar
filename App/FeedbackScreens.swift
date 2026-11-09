import SwiftUI

// What the user's thumbs do to the feed, shown and adjustable. A paper on the reading list or marked For
// me pulls the feed toward what is like it; a paper hidden pushes it away. Neither lasts for ever: only
// the newest few count, and an age limit can drop the rest. The rules are in Core/FeedbackMemory.swift.

struct FeedbackScreen: View {
    @Environment(AppModel.self) private var appModel

    private static let halfLives: [(label: String, months: Int)] = [
        ("Never", 0), ("3 months", 3), ("6 months", 6), ("12 months", 12), ("24 months", 24),
    ]

    var body: some View {
        @Bindable var model = appModel
        let feedback = model.settings.feedback
        let lowered = model.layout.all.filter { $0.paper.loweredBy != nil }.count
        Form {
            Section {
                NavigationLink { FeedbackListScreen(kind: .saved) } label: {
                    LabeledContent("Reading list", value: "\(feedback.saved.count)")
                }
                NavigationLink { FeedbackListScreen(kind: .liked) } label: {
                    LabeledContent("For me", value: "\(feedback.liked.count)")
                }
                NavigationLink { FeedbackListScreen(kind: .hidden) } label: {
                    LabeledContent("Hidden", value: "\(feedback.hidden.count)")
                }
            } header: {
                Text("What you have told it")
            } footer: {
                Text("Open one to see how much each paper still counts, to stop counting one without deleting it, or to take it back.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("How much they count")
                    Slider(value: $model.settings.likeStrength, in: 0...1)
                    HStack {
                        Text("Not at all").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("As much as your own papers").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Stepper("Only the newest \(model.settings.likeMemory) count",
                        value: $model.settings.likeMemory, in: 20...1000, step: 20)
                Picker("Halve their weight every", selection: $model.settings.likeHalfLifeMonths) {
                    ForEach(Self.halfLives, id: \.months) { Text($0.label).tag($0.months) }
                }
            } header: {
                Text("Pull toward what I like")
            } footer: {
                Text("The reading list and For me are counted together. The newest counts fully, the oldest of those that count a quarter as much. With a fade, a paper also loses half its weight every period, and counts for nothing once it has faded to a few percent, so the feed follows where you are now. A paper kept before dates were recorded began to fade the day this was added.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("How hard they push")
                    Slider(value: $model.settings.hideStrength, in: 0...1)
                    HStack {
                        Text("Off").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Strongly").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Stepper("Only the newest \(model.settings.hideMemory) count",
                        value: $model.settings.hideMemory, in: 10...500, step: 10)
                Picker("Halve their weight every", selection: $model.settings.hideHalfLifeMonths) {
                    ForEach(Self.halfLives, id: \.months) { Text($0.label).tag($0.months) }
                }
            } header: {
                Text("Push away from what I hid")
            } footer: {
                Text("A hidden paper stays hidden whatever you set here: these settings only decide whether similar papers are lowered. Only papers hidden since this was added teach the feed. A paper is lowered only if it is among the few closest to what you hid and closer to that than to anything you want, so a field you have come to want is not lowered. What you follow, and what cites your work, is never lowered.")
            }

            Section {
                NavigationLink { PulledScreen() } label: { Label("Pulled up by what you like", systemImage: "arrow.up.circle") }
                NavigationLink { LoweredScreen() } label: {
                    LabeledContent {
                        Text(lowered == 0 ? "None" : "\(lowered)")
                    } label: {
                        Label("Pushed down by what you hid", systemImage: "arrow.down.circle")
                    }
                }
            } header: {
                Text("What it is doing to your feed now")
            } footer: {
                Text("Moving a slider or a limit ranks the feed again when you go back to it. Nothing is fetched again.")
            }
        }
        .navigationTitle("Your feedback")
    }
}

/// The papers behind one count, each with how much it still counts.
struct FeedbackListScreen: View {
    @Environment(AppModel.self) private var model
    let kind: Feedback.Kind

    private var title: String {
        switch kind {
        case .saved: return "Reading list"
        case .liked: return "For me"
        case .hidden: return "Hidden"
        }
    }

    var body: some View {
        let s = model.settings
        let weights = kind == .hidden ? FeedbackMemory.hideWeights(s) : FeedbackMemory.likeWeights(s)
        let items: [SavedPaper] = switch kind {
        case .saved: s.feedback.saved.reversed()
        case .liked: s.feedback.liked.reversed()
        case .hidden: s.feedback.hiddenPapers.reversed()
        }
        // Papers hidden before their text was kept: only an id, which teaches nothing.
        let known = Set(s.feedback.hiddenPapers.map(\.id))
        let orphans = kind == .hidden ? s.feedback.hidden.filter { !known.contains($0) } : []
        List {
            Section {
                if items.isEmpty && orphans.isEmpty { Text("Nothing here.").foregroundStyle(.secondary) }
                ForEach(items, id: \.id) { paper in
                    row(paper, weight: weights[paper.id] ?? 0)
                }
                ForEach(orphans, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(SavedPaper.readable(id)).font(.headline)
                        Text("Hidden before its text was kept: it stays hidden and teaches nothing")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Show again") { model.removeFeedback(id: id, in: .hidden) }.tint(.blue) }
                }
            } footer: {
                if kind == .hidden {
                    Text("Swipe left to show a paper again and forget what it taught. Swipe right to stop counting it without showing it.")
                } else {
                    Text("Swipe left to take a paper off. Swipe right to stop counting it without deleting it.")
                }
            }
            if kind == .hidden, !s.feedback.hidden.isEmpty {
                Button("Show all hidden papers again", role: .destructive) {
                    for id in s.feedback.hidden { model.removeFeedback(id: id, in: .hidden) }
                }
            }
        }
        .navigationTitle(title)
    }

    private func row(_ paper: SavedPaper, weight: Double) -> some View {
        let ignored = paper.ignored == true
        return VStack(alignment: .leading, spacing: 3) {
            Text(Html.plain(paper.title)).font(.headline).foregroundStyle(ignored || weight <= 0 ? Color.secondary : Color.primary)
            Text(detail(paper, weight: weight)).font(.caption).foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button(kind == .hidden ? "Show again" : "Take off", role: kind == .hidden ? nil : .destructive) {
                model.removeFeedback(id: paper.id, in: kind)
            }
            .tint(kind == .hidden ? .blue : nil)
        }
        .swipeActions(edge: .leading) {
            Button(ignored ? "Count again" : "Ignore") { model.setIgnored(!ignored, id: paper.id, in: kind) }
                .tint(.orange)
        }
    }

    private func detail(_ paper: SavedPaper, weight: Double) -> String {
        let when = paper.keptAt.map { "Kept " + Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) }
            ?? "Kept before dates were recorded"
        return when + " · " + FeedbackMemory.standing(weight: weight, ignored: paper.ignored == true)
    }
}

/// The papers in the feed that were lowered, as the last ranking left them: exact, and at once.
struct LoweredScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lowered = model.layout.all.map(\.paper).filter { $0.loweredBy != nil }
        List {
            if lowered.isEmpty {
                ContentUnavailableView {
                    Label("Nothing is lowered", systemImage: "arrow.down.circle")
                } description: {
                    Text("A paper is lowered only if it is among the closest to one you hid and closer to that than to anything you want. Hide a few papers and the feed will show here what they lower the next time it is ranked.")
                }
            } else {
                Section {
                    ForEach(lowered, id: \.id) { paper in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Html.plain(paper.title)).font(.headline)
                            Label("Like “\(paper.loweredBy ?? "")”, which you hid", systemImage: "arrow.down.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("These are in the feed, lower than they would be. Only the next ranking changes this list.")
                }
            }
        }
        .navigationTitle("Pushed down")
    }
}

/// The papers most like what the user put on the reading list or marked For me.
struct PulledScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pulled: [Ranker.Influence.Pull]?

    var body: some View {
        List {
            if let pulled {
                if pulled.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "arrow.up.circle")
                    } description: {
                        Text("Add papers to your reading list or mark some For me, and the papers in your feed most like them will be listed here.")
                    }
                } else {
                    Section {
                        ForEach(pulled, id: \.paper.id) { pull in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Html.plain(pull.paper.title)).font(.headline)
                                Label("Like “\(pull.because)”", systemImage: "arrow.up.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("The papers in your feed that are closest to what you like, each with the paper it is like. They rank higher for it.")
                    }
                }
            } else {
                HStack { ProgressView(); Text("Comparing…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Pulled up")
        .task { pulled = await model.likedInfluence() }
    }
}

extension SavedPaper {
    /// What can be said of a paper known only by its id.
    static func readable(_ id: String) -> String {
        if id.hasPrefix("doi:") { return "DOI " + id.dropFirst(4) }
        if id.hasPrefix("pmid:") { return "PubMed " + id.dropFirst(5) }
        return "A hidden paper"
    }
}
