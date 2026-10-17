import PomodoroCore
import SwiftUI

@main
struct PomodoroApp: App {
    var body: some Scene {
        MenuBarExtra("Pomodoro", systemImage: "timer") {
            PopoverView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("Pomodoro \(Version.current.description)")
                .padding()
                .frame(width: 320, height: 160)
        }
    }
}
