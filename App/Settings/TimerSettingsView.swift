import PomodoroCore
import SwiftUI

/// Edits the default preset's profile; presets and one-offs are layered on top of it.
struct TimerSettingsView: View {
    static let standardNudges = [5, 10, 15, 20, 30]

    var model: AppModel

    private var profile: TimerProfile { model.settings.defaultProfile }

    var body: some View {
        Form {
            Section {
                MinutesField(title: "Focus", minutes: model.defaultProfileBinding(\.focusDuration).minutes)
                MinutesField(title: "Short break", minutes: model.defaultProfileBinding(\.shortBreakDuration).minutes)
                MinutesField(title: "Long break", minutes: model.defaultProfileBinding(\.longBreakDuration).minutes)
                LabeledContent("Long break after") {
                    HStack(spacing: 6) {
                        Text(profile.longBreakEvery == 1 ? "every focus" : "\(profile.longBreakEvery) focuses")
                            .monospacedDigit()
                        Stepper(
                            "Long break after",
                            value: model.defaultProfileBinding(\.longBreakEvery),
                            in: TimerProfile.longBreakEveryRange
                        )
                        .labelsHidden()
                    }
                }
            } header: {
                Text("Durations")
            } footer: {
                Text("Changes apply to \(model.settings.defaultPreset.name), your default preset.")
                    .foregroundStyle(.secondary)
            }

            Section("Overtime") {
                Toggle(isOn: model.defaultProfileBinding(\.flowMode)) {
                    Text("Flow mode")
                    Text("When a phase ends, keep counting overtime until you choose what's next.")
                }
                Picker("Remind me every", selection: nudgeMinutes) {
                    Text("Off").tag(Int?.none)
                    Divider()
                    ForEach(nudgeChoices, id: \.self) { minutes in
                        Text("\(minutes) min").tag(Int?.some(minutes))
                    }
                }
                .disabled(!profile.flowMode)
            }

            Section("Auto-start") {
                Toggle("Start breaks automatically", isOn: model.defaultProfileBinding(\.autoStartBreaks))
                Toggle("Start focus after a break", isOn: model.defaultProfileBinding(\.autoStartFocus))
            }
        }
        .formStyle(.grouped)
    }

    private var nudgeMinutes: Binding<Int?> {
        let interval = model.defaultProfileBinding(\.nudgeInterval)
        return Binding(
            get: { interval.wrappedValue.map { Int(($0 / 60).rounded()) } },
            set: { interval.wrappedValue = $0.map { TimeInterval($0) * 60 } }
        )
    }

    /// Lists a stored interval that isn't a standard choice, so the picker never shows blank.
    private var nudgeChoices: [Int] {
        guard let current = nudgeMinutes.wrappedValue, !Self.standardNudges.contains(current) else { return Self.standardNudges }
        return (Self.standardNudges + [current]).sorted()
    }
}
