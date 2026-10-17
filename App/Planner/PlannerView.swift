import PomodoroCore
import SwiftUI

struct PlannerView: View {
    static let size = CGSize(width: 820, height: 560)
    static let sidebarWidth: CGFloat = 300

    var model: AppModel

    @State private var timeline: TimelineStore

    init(model: AppModel, timeline: TimelineStore? = nil) {
        self.model = model
        _timeline = State(initialValue: timeline ?? TimelineStore(model: model))
    }

    var body: some View {
        // A plain split rather than NavigationSplitView: the timeline owns the detail pane's
        // layout, and a NavigationSplitView sidebar doesn't render outside a live window.
        HStack(spacing: 0) {
            TaskListView(model: model)
                .frame(width: Self.sidebarWidth)
            Divider()
            DayTimelineView(store: timeline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
