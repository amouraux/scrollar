import SwiftUI

struct SavedView: View {
    @Environment(AppModel.self) private var model
    @State private var list: Tab = .saved
    @State private var filter = SavedFilter()
    /// Wide windows keep the panel beside the list; a narrow one opens it as a sheet.
    @State private var panelShown = true
    @State private var panelSheet = false

    enum Tab: String, CaseIterable { case saved = "Saved", liked = "For me", read = "Read" }

    /// Papers kept before reasons were stored get them from the feed where it still holds them.
    private var entries: [(paper: SavedPaper, subtitle: String)] {
        let feed = model.layout.all.map(\.paper)
        switch list {
        case .saved:
            return SavedFilter.enriched(model.settings.feedback.saved.reversed(), from: feed).map { ($0, $0.date) }
        case .liked:
            return SavedFilter.enriched(model.settings.feedback.liked.reversed(), from: feed).map { ($0, $0.date) }
        case .read:
            let read = model.history.read
            let papers = SavedFilter.enriched(read.map(\.paper), from: feed)
            return zip(papers, read).map { ($0, "Read " + $1.date.formatted(.relative(presentation: .named))) }
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width >= 700
                let all = entries
                HStack(spacing: 0) {
                    if wide && panelShown {
                        SavedFilterPanel(items: all.map(\.paper), filter: $filter)
                            .frame(width: 310)
                        Divider()
                    }
                    VStack(spacing: 0) {
                        Picker("List", selection: $list) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16).padding(.bottom, 8)

                        content(all)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { exportButton }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if wide { withAnimation { panelShown.toggle() } } else { panelSheet = true }
                        } label: {
                            Label("Filter", systemImage: filter.isActive
                                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .sheet(isPresented: $panelSheet) {
                    NavigationStack {
                        SavedFilterPanel(items: all.map(\.paper), filter: $filter)
                            .navigationTitle("Filter")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panelSheet = false } } }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .navigationTitle(list.rawValue)
        }
        // A kind that exists in one list may not in another.
        .onChange(of: list) { filter.kind = nil; filter.detail = nil }
    }

    @ViewBuilder private func content(_ all: [(paper: SavedPaper, subtitle: String)]) -> some View {
        if all.isEmpty {
            emptyState
        } else {
            let shown = filter.apply(all.map(\.paper))
            let subtitles = Dictionary(all.map { ($0.paper.id, $0.subtitle) }, uniquingKeysWith: { a, _ in a })
            if shown.isEmpty {
                ContentUnavailableView {
                    Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No paper in this list fits the filter.")
                } actions: {
                    Button("Clear filter") { filter.kind = nil; filter.detail = nil; filter.query = "" }
                }
            } else {
                List {
                    ForEach(shown, id: \.id) { paper in
                        row(paper, subtitle: subtitles[paper.id] ?? paper.date)
                            .swipeActions { swipe(paper) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func swipe(_ paper: SavedPaper) -> some View {
        switch list {
        case .saved:
            Button("Remove", role: .destructive) { model.settings.feedback.saved.removeAll { $0.id == paper.id } }
        case .liked:
            Button("Take back", role: .destructive) { model.settings.feedback.unlike(paper.id) }
        case .read:
            EmptyView()
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch list {
        case .saved:
            ContentUnavailableView("Nothing saved", systemImage: "bookmark",
                                   description: Text("Papers you save are kept here, and teach the feed what you want more of."))
        case .liked:
            // The only place to take it back once the post has left the feed.
            ContentUnavailableView("Nothing marked for you", systemImage: "hand.thumbsup",
                                   description: Text("Use For me on a paper you know and like. It teaches the feed what you want without saving the paper."))
        case .read:
            ContentUnavailableView("Nothing read yet", systemImage: "checkmark.circle",
                                   description: Text("Papers you open, or read in full, are kept here, and leave the feed."))
        }
    }

    /// Every paper on the list as one `.ris` file for a reference manager. Papers saved before
    /// authors were kept are filled in from the feed where it still holds them. The whole list is
    /// exported, not only what the filter shows: a filter is a way of looking, not of choosing.
    @ViewBuilder private var exportButton: some View {
        let items = entries.map(\.paper)
        if !items.isEmpty {
            let layout = model.layout
            let name = "Scrollar \(list.rawValue.lowercased()) papers.ris"
            ShareLink(item: ReferenceFile(name: name, make: { RIS.references(items, known: layout.all.map(\.paper)) }),
                      preview: SharePreview(name, image: Image(systemName: "books.vertical"))) {
                Label("Export for a reference manager", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func row(_ paper: SavedPaper, subtitle: String) -> some View {
        let title = Html.plain(paper.title)
        let tags = SavedFilter.tags(of: paper)
        return VStack(alignment: .leading, spacing: 4) {
            if let url = paper.link {
                Link(destination: url) {
                    Text(title).font(.headline).multilineTextAlignment(.leading)
                }
            } else {
                Text(title).font(.headline)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            if let first = tags.first {
                Label(Why.text(for: first) + (tags.count > 1 ? " · +\(tags.count - 1)" : ""),
                      systemImage: first.kind.symbol)
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
            }
            if let abstract = paper.abstract {
                Text(abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

/// Sort, search and the classes of the papers on the list: the kinds of reason they reached the
/// feed for, and the names within a kind. Choosing one filters the list; choosing it again clears it.
private struct SavedFilterPanel: View {
    let items: [SavedPaper]
    @Binding var filter: SavedFilter

    var body: some View {
        let facets = SavedFilter.facets(items)
        List {
            Section {
                Picker("Sort by", selection: $filter.sort) {
                    ForEach(SavedFilter.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Title, author or journal", text: $filter.query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            Section("Relevant to me because") {
                row("All papers", symbol: "tray.full", count: items.count, selected: filter.kind == nil, indent: false) {
                    filter.kind = nil; filter.detail = nil
                }
                ForEach(facets, id: \.self) { facet in
                    let selected = filter.kind == facet.kind && filter.detail == facet.detail
                    row(facet.detail ?? facet.kind.title, symbol: facet.detail == nil ? facet.kind.symbol : nil,
                        count: facet.count, selected: selected, indent: facet.detail != nil) {
                        if selected { filter.kind = nil; filter.detail = nil }
                        else { filter.kind = facet.kind; filter.detail = facet.detail }
                    }
                }
            }
            if filter.isActive {
                Button("Clear filter") { filter.kind = nil; filter.detail = nil; filter.query = "" }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, symbol: String?, count: Int, selected: Bool, indent: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).frame(width: 20) }
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.leading, indent ? 28 : 0)
            .fontWeight(selected ? .semibold : .regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
