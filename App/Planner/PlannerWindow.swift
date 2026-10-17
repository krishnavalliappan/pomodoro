import PomodoroCore
import SwiftUI

/// The planner window's content: the day plan or the stats, switched from a bar above both.
/// `PlannerView` stays as it is, so the timeline's layout is its own.
struct PlannerWindow: View {
    enum Tab: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case stats = "Stats"

        var id: Self { self }
    }

    static let switcherHeight: CGFloat = 40
    static let size = CGSize(width: PlannerView.size.width, height: PlannerView.size.height + switcherHeight)

    var model: AppModel

    @State private var tab: Tab
    // Owned here so switching tabs keeps the day and week on show.
    @State private var timeline: TimelineStore
    @State private var stats: StatsStore

    init(model: AppModel, tab: Tab = .plan) {
        self.model = model
        _tab = State(initialValue: tab)
        _timeline = State(initialValue: TimelineStore(model: model))
        _stats = State(initialValue: StatsStore(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .frame(height: Self.switcherHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            switch tab {
            case .plan: PlannerView(model: model, timeline: timeline)
            case .stats: StatsView(model: model, store: stats)
            }
        }
        .background(shortcuts)
    }

    /// ⌘1 and ⌘2 switch tabs, as in other Mac apps with a segmented switch.
    private var shortcuts: some View {
        ZStack {
            Button("Plan") { tab = .plan }
                .keyboardShortcut("1", modifiers: .command)
            Button("Stats") { tab = .stats }
                .keyboardShortcut("2", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
