import PomodoroCore
import SwiftUI

/// Stands in until the settings window lands (#12).
struct SettingsPlaceholderView: View {
    static let size = CGSize(width: 420, height: 260)

    var body: some View {
        ContentUnavailableView {
            Label("Settings", systemImage: "gearshape")
        } description: {
            VStack(spacing: 8) {
                Text("Durations, sounds and the menu bar display will be configurable here.")
                Text("Pomodoro \(Version.current.description)")
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
