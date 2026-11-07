import SwiftUI

@main
struct ScrollarApp: App {
    @State private var model = AppModel()
    @State private var tab: Tab = .feed

    enum Tab { case feed, saved, settings }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                FeedView()
                    .tabItem { Label("Feed", systemImage: "text.justify.leading") }
                    .tag(Tab.feed)
                SavedView()
                    .tabItem { Label("Saved", systemImage: "bookmark") }
                    .tag(Tab.saved)
                SettingsView()
                    .tabItem { Label("Tune", systemImage: "slider.horizontal.3") }
                    .tag(Tab.settings)
            }
            .environment(model)
            .task { await model.refreshIfStale() }
            // Changes made in Tune are applied when the user goes back to the feed,
            // not on every tap.
            .onChange(of: tab) { _, new in
                if new == .feed, model.needsRefresh { Task { await model.refresh() } }
            }
        }
    }
}
