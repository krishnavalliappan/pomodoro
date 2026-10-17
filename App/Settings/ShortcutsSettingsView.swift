import KeyboardShortcuts
import SwiftUI

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(Hotkey.allCases) { hotkey in
                    KeyboardShortcuts.Recorder(hotkey.title, name: hotkey.name)
                }
            } footer: {
                Text("These work from any app. None are set until you record one, so nothing clashes with your other shortcuts.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
