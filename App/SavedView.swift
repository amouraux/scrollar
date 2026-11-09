import SwiftUI

struct SavedView: View {
    @Environment(AppModel.self) private var model
    @State private var list: Tab = .saved
    @State private var filter = SavedFilter()
    /// On the reading list only: leave out what has been opened, as Safari's list can.
    @State private var unreadOnly = false
    /// Wide windows keep the panel beside the list; a narrow one opens it as a sheet.
    @State private var panelShown = true
    @State private var panelSheet = false

    /// What the user adds to read later; what they have read; what they marked as being for them.
    enum Tab: String, CaseIterable { case saved = "Reading list", read = "Read", liked = "For me" }

    /// Papers kept before reasons were stored get them from the feed where it still holds them.
    private var entries: [(paper: SavedPaper, subtitle: String)] {
        let feed = model.layout.all.map(\.paper)
        switch list {
        case .saved:
            return SavedFilter.enriched(model.settings.feedback.saved.reversed(), from: feed)
                .map { ($0, isRead($0) ? $0.date + " · Read" : $0.date) }
        case .liked:
            return SavedFilter.enriched(model.settings.feedback.liked.reversed(), from: feed).map { ($0, $0.date) }
        case .read:
            let read = model.history.read
            let papers = SavedFilter.enriched(read.map(\.paper), from: feed)
            return zip(papers, read).map { ($0, "Read " + $1.date.formatted(.relative(presentation: .named))) }
        }
    }

    private func isRead(_ paper: SavedPaper) -> Bool { model.history.status(of: paper.id) == .read }

    /// What the filter leaves; on the reading list, with what was opened left out if asked.
    private func visible(_ papers: [SavedPaper]) -> [SavedPaper] {
        let kept = filter.apply(papers)
        return list == .saved && unreadOnly ? kept.filter { !isRead($0) } : kept
    }

    private var filtering: Bool { filter.isActive || (list == .saved && unreadOnly) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width >= 700
                let all = entries
                HStack(spacing: 0) {
                    if wide && panelShown {
                        SavedFilterPanel(items: all.map(\.paper), filter: $filter, unreadOnly: list == .saved ? $unreadOnly : nil)
                            .frame(width: 310)
                            // Its own tint, so the panel reads as a side bar and not as more list.
                            .background(Color.accentColor.opacity(0.08))
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
                    // Room between the panel and the list's own rounded card.
                    .padding(.leading, wide && panelShown ? 12 : 0)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { exportButton }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if wide { withAnimation { panelShown.toggle() } } else { panelSheet = true }
                        } label: {
                            Label("Filter", systemImage: filtering
                                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                .sheet(isPresented: $panelSheet) {
                    NavigationStack {
                        SavedFilterPanel(items: all.map(\.paper), filter: $filter, unreadOnly: list == .saved ? $unreadOnly : nil)
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
            let shown = visible(all.map(\.paper))
            let subtitles = Dictionary(all.map { ($0.paper.id, $0.subtitle) }, uniquingKeysWith: { a, _ in a })
            if shown.isEmpty {
                ContentUnavailableView {
                    Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No paper in this list fits the filter.")
                } actions: {
                    Button("Clear filter") { filter.kind = nil; filter.detail = nil; filter.query = ""; unreadOnly = false }
                }
            } else {
                List {
                    ForEach(shown, id: \.id) { paper in
                        row(paper, subtitle: subtitles[paper.id] ?? paper.date)
                            .swipeActions { swipe(paper) }
                            // Separate from the list: it puts the paper in the reference manager, whichever list this is.
                            .swipeActions(edge: .leading) { zoteroButton(paper).tint(.blue) }
                            .contextMenu {
                                zoteroButton(paper)
                                if list == .saved {
                                    Button("Remove from reading list", systemImage: "minus.circle", role: .destructive) {
                                        model.settings.feedback.saved.removeAll { $0.id == paper.id }
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    /// Only offered with a Zotero key that may write: elsewhere there is nothing it could do.
    @ViewBuilder private func zoteroButton(_ paper: SavedPaper) -> some View {
        if model.zotero?.canWrite == true {
            Button("Add to Zotero", systemImage: "tray.and.arrow.down") { Task { await model.addToZotero(paper) } }
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
            ContentUnavailableView("Nothing on your reading list", systemImage: "eyeglasses",
                                   description: Text("Papers you add with Read later are kept here, and teach the feed what you want more of."))
        case .liked:
            // The only place to take it back once the post has left the feed.
            ContentUnavailableView("Nothing marked for you", systemImage: "hand.thumbsup",
                                   description: Text("Use For me on a paper you know and like. It teaches the feed what you want without adding the paper to your reading list."))
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
            // A paper already opened is dimmed on the reading list, so what is left to read stands out.
            let dimmed = list == .saved && isRead(paper)
            if let url = paper.link {
                Link(destination: url) {
                    Text(title).font(.headline).multilineTextAlignment(.leading)
                        .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                }
            } else {
                Text(title).font(.headline).foregroundStyle(dimmed ? Color.secondary : Color.primary)
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
    /// Offered on the reading list only.
    var unreadOnly: Binding<Bool>?

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
                if let unreadOnly { Toggle("Unread only", isOn: unreadOnly) }
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
            if filter.isActive || (unreadOnly?.wrappedValue ?? false) {
                Button("Clear filter") { filter.kind = nil; filter.detail = nil; filter.query = ""; unreadOnly?.wrappedValue = false }
            }
        }
        // Plain rows on the panel's own tint: the grouped style drew grey boxes that met the list's.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
