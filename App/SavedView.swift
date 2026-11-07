import SwiftUI

struct SavedView: View {
    @Environment(AppModel.self) private var model
    @State private var list: Tab = .saved

    enum Tab: String, CaseIterable { case saved = "Saved", read = "Read" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("List", selection: $list) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.bottom, 8)

                switch list {
                case .saved: savedList
                case .read: readList
                }
            }
            .navigationTitle(list.rawValue)
        }
    }

    @ViewBuilder private var savedList: some View {
        if model.settings.feedback.saved.isEmpty {
            ContentUnavailableView("Nothing saved", systemImage: "bookmark",
                                   description: Text("Papers you save are kept here, and teach the feed what you want more of."))
        } else {
            List {
                ForEach(model.settings.feedback.saved.reversed(), id: \.id) { paper in
                    row(title: paper.title, subtitle: paper.date, abstract: paper.abstract, url: paper.link)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                model.settings.feedback.saved.removeAll { $0.id == paper.id }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder private var readList: some View {
        let read = model.history.read
        if read.isEmpty {
            ContentUnavailableView("Nothing read yet", systemImage: "checkmark.circle",
                                   description: Text("Papers you open, or read in full, are kept here, and leave the feed."))
        } else {
            List {
                ForEach(read, id: \.paper.id) { item in
                    row(title: item.paper.title,
                        subtitle: "Read " + item.date.formatted(.relative(presentation: .named)),
                        abstract: item.paper.abstract, url: item.paper.link)
                }
            }
        }
    }

    private func row(title: String, subtitle: String, abstract: String?, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url {
                Link(destination: url) {
                    Text(title).font(.headline).multilineTextAlignment(.leading)
                }
            } else {
                Text(title).font(.headline)
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            if let abstract {
                Text(abstract).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}
