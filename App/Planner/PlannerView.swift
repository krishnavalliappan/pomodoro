import PomodoroCore
import SwiftUI

struct PlannerView: View {
    static let size = CGSize(width: 820, height: 560)
    static let sidebarWidth: CGFloat = 300

    var model: AppModel

    var body: some View {
        // A plain split rather than NavigationSplitView: the timeline (#11) owns the detail pane's
        // layout, and a NavigationSplitView sidebar doesn't render outside a live window.
        HStack(spacing: 0) {
            TaskListView(model: model)
                .frame(width: Self.sidebarWidth)
            Divider()
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
