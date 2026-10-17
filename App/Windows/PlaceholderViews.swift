import PomodoroCore
import SwiftUI

/// Stands in until the day timeline lands (#11).
struct PlannerPlaceholderView: View {
    static let size = CGSize(width: 640, height: 480)

    var body: some View {
        ContentUnavailableView {
            Label("Planner", systemImage: "calendar")
        } description: {
            Text("Your day timeline and task list will live here.")
        }
        .frame(minWidth: 480, minHeight: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Stands in until the settings window lands (#12).
struct SettingsPlaceholderView: View {
    static let size = CGSize(width: 420, height: 260)

    var body: some View {
        ContentUnavailableView {
            Label("Settings", systemImage: "gearshape")
        } description: {
            Text("Durations, sounds and the menu bar display will be configurable here.\nPomodoro \(Version.current.description)")
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
