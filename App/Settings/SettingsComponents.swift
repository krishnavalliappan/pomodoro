import PomodoroCore
import SwiftUI

extension AppModel {
    /// Reads from and writes through `updateSettings`, so every edit saves and reschedules.
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    func defaultProfileBinding<Value>(_ keyPath: WritableKeyPath<TimerProfile, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings.defaultProfile[keyPath: keyPath] },
            set: { value in self.updateSettings { $0.updateDefaultProfile { $0[keyPath: keyPath] = value } } }
        )
    }
}

extension Binding where Value == TimeInterval {
    /// Whole minutes, the unit every duration control shows.
    var minutes: Binding<Int> {
        Binding<Int>(
            get: { Int((wrappedValue / 60).rounded()) },
            set: { wrappedValue = TimeInterval($0) * 60 }
        )
    }
}

/// A duration in minutes: type it or step it.
struct MinutesField: View {
    var title: String
    @Binding var minutes: Int
    var range: ClosedRange<Int> = Int(TimerProfile.durationRange.lowerBound / 60)...Int(TimerProfile.durationRange.upperBound / 60)
    var unit = "min"

    private var clamped: Binding<Int> {
        Binding(get: { minutes }, set: { minutes = min(max($0, range.lowerBound), range.upperBound) })
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: clamped, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                Text(unit)
                    .foregroundStyle(.secondary)
                Stepper(title, value: clamped, in: range)
                    .labelsHidden()
            }
        }
    }
}

extension SoundID {
    var title: String {
        switch self {
        case .chimeFocusEnd: "Warm chime"
        case .chimeBreakEnd: "Bright chime"
        case .start: "Pop"
        case .tick: "Tick"
        case .bowl: "Singing bowl"
        case .none: "None"
        }
    }
}

extension SoundEvent {
    var settingsPath: WritableKeyPath<AppSettings, SoundID> {
        switch self {
        case .focusEnd: \.sounds.focusEnd
        case .breakEnd: \.sounds.breakEnd
        case .start: \.sounds.start
        case .tick: \.sounds.tick
        }
    }

    var title: String {
        switch self {
        case .focusEnd: "Focus ends"
        case .breakEnd: "Break ends"
        case .start: "Session starts"
        case .tick: "Tick during focus"
        }
    }
}

extension MenuBarDisplayMode {
    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .time: "Time"
        case .timeAndTask: "Time and task"
        }
    }
}
