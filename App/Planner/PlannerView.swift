import PomodoroCore
import SwiftUI

struct PlannerView: View {
    static let size = CGSize(width: 820, height: 560)
    static let sidebarWidth: CGFloat = 300

    var model: AppModel

    var body: some View {
        NavigationSplitView {
            TaskListView(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: Self.sidebarWidth, max: 420)
        } detail: {
            TimelinePlaceholder()
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// Stands in until the day timeline lands (#11).
struct TimelinePlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Timeline", systemImage: "calendar.day.timeline.left")
        } description: {
            Text("Timeline (coming in #11)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
