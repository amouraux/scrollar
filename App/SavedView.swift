import SwiftUI

struct SavedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.settings.feedback.saved.isEmpty {
                    ContentUnavailableView("Nothing saved", systemImage: "bookmark",
                                           description: Text("Papers you save are kept here, and teach the feed what you want more of."))
                } else {
                    List {
                        ForEach(model.settings.feedback.saved.reversed(), id: \.id) { paper in
                            VStack(alignment: .leading, spacing: 4) {
                                if let url = paper.link {
                                    Link(destination: url) {
                                        Text(paper.title).font(.headline).multilineTextAlignment(.leading)
                                    }
                                } else {
                                    Text(paper.title).font(.headline)
                                }
                                Text(paper.date).font(.caption).foregroundStyle(.secondary)
                                if let a = paper.abstract {
                                    Text(a).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    model.settings.feedback.saved.removeAll { $0.id == paper.id }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Saved")
        }
    }
}
