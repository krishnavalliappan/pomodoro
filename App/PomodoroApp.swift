import PomodoroCore
import SwiftUI

@main
struct PomodoroApp: App {
    // Created with the app so every player is preloaded before the first chime.
    @State private var sound = SoundService()

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
