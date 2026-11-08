import SwiftUI
import UIKit

@main
struct ScrollarApp: App {
    @State private var model = AppModel()
    @State private var tab: Tab = .feed
    @Environment(\.scenePhase) private var scenePhase

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
            .task {
                // The other device's follows come first, so the refresh builds for them.
                await model.syncNow(rearrange: true)
                await model.refreshIfStale()
            }
            #if targetEnvironment(macCatalyst)
            // A window that is too small to hold a post is no use; keep it readable.
            .onAppear {
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 640)
                }
            }
            #endif
            // What has been seen is written out when the app leaves the screen.
            .onChange(of: scenePhase) { _, new in
                if new != .active {
                    model.saveHistoryNow()
                    Task { await model.syncNow() }
                }
                // The app is often resumed, not launched: the other device is read, and a
                // feed more than six hours old is refreshed, behind the "new papers" pill.
                if new == .active {
                    Task {
                        await model.syncNow(rearrange: true)
                        await model.refreshIfStale()
                    }
                }
            }
            // Changes made in Tune are applied when the user goes back to the feed,
            // not on every tap.
            .onChange(of: tab) { _, new in
                if new == .feed, model.needsRefresh { Task { await model.refresh() } }
            }
        }
        // Menu items on the Mac, and the shortcut sheet on an iPad with a keyboard.
        // There is no pull-to-refresh with a mouse, so refreshing needs a command.
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Feed") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Divider()
                Button("Feed") { tab = .feed }.keyboardShortcut("1")
                Button("Saved") { tab = .saved }.keyboardShortcut("2")
                Button("Tune") { tab = .settings }.keyboardShortcut("3")
            }
        }
    }
}
