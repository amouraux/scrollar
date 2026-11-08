import SwiftUI

/// Adds up the time a post is actually in front of the reader: at least half of it on screen and the app
/// active. The total is reported each time it stops (the post scrolls away, the app goes to the
/// background, the view goes), so `onDwell` is called with each stretch, not with a running figure.
///
/// A lazy stack builds a view a little before it is visible, so `onAppear` alone would count time
/// nobody saw. From iOS 18 the scroll view reports how much of a view is visible; earlier, the
/// appearance stands in for it.
struct DwellTracking: ViewModifier {
    @Environment(\.scenePhase) private var phase
    let onDwell: (Double) -> Void
    @State private var visible = false
    @State private var since: Date?

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 18, *) {
                content.onScrollVisibilityChange(threshold: 0.5) { set($0) }
            } else {
                content.onAppear { set(true) }
            }
        }
        .onDisappear { set(false) }
        .onChange(of: phase) { _, _ in update() }
    }

    private func set(_ now: Bool) {
        visible = now
        update()
    }

    private func update() {
        let counting = visible && phase == .active
        if counting, since == nil {
            since = Date()
        } else if !counting, let start = since {
            since = nil
            onDwell(Date().timeIntervalSince(start))
        }
    }
}

extension View {
    func trackingDwell(_ onDwell: @escaping (Double) -> Void) -> some View {
        modifier(DwellTracking(onDwell: onDwell))
    }
}
