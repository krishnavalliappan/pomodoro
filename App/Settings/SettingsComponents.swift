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

/// What a minutes field shows while the user types. Only `commit` writes, so the "1" on the way
/// to "15" never saves settings, reschedules a timer, or becomes an auto-started break's length.
struct MinutesDraft: Equatable {
    var range: ClosedRange<Int>
    /// Typed since the last commit; nil shows the stored value.
    var text: String?

    func displayed(_ minutes: Int) -> String {
        text ?? String(minutes)
    }

    /// The clamped typed number, or the stored value when the text isn't one.
    func value(_ minutes: Int) -> Int {
        guard let text, let typed = Int(text.trimmingCharacters(in: .whitespaces)) else { return minutes }
        return min(max(typed, range.lowerBound), range.upperBound)
    }

    /// Writes once, then shows the stored (possibly clamped) value again.
    mutating func commit(to minutes: Binding<Int>) {
        let value = value(minutes.wrappedValue)
        text = nil
        if value != minutes.wrappedValue { minutes.wrappedValue = value }
    }
}

/// A duration in minutes: type it or step it.
struct MinutesField: View {
    static let defaultRange = Int(TimerProfile.durationRange.lowerBound / 60)...Int(TimerProfile.durationRange.upperBound / 60)

    var title: String
    @Binding var minutes: Int
    var range: ClosedRange<Int>
    var unit = "min"
    /// For a sheet's local draft: its Save button reads the value without the field losing focus
    /// first, and writing there saves nothing. Settings bindings commit on Return or focus loss.
    var writesWhileTyping = false

    @State private var draft: MinutesDraft
    @FocusState private var isFocused: Bool

    init(title: String, minutes: Binding<Int>, range: ClosedRange<Int> = Self.defaultRange, unit: String = "min", writesWhileTyping: Bool = false) {
        self.title = title
        _minutes = minutes
        self.range = range
        self.unit = unit
        self.writesWhileTyping = writesWhileTyping
        _draft = State(initialValue: MinutesDraft(range: range))
    }

    private var text: Binding<String> {
        Binding(
            get: { draft.displayed(minutes) },
            set: { text in
                draft.text = text
                if writesWhileTyping {
                    let value = draft.value(minutes)
                    if value != minutes { minutes = value }
                }
            }
        )
    }

    /// Steps from what's typed, and writes once.
    private var stepped: Binding<Int> {
        Binding(
            get: { draft.value(minutes) },
            set: { value in
                draft.text = String(value)
                draft.commit(to: $minutes)
            }
        )
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 44)
                    .focused($isFocused)
                    .onSubmit { draft.commit(to: $minutes) }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { draft.commit(to: $minutes) }
                    }
                    .onDisappear { draft.commit(to: $minutes) }
                Text(unit)
                    .foregroundStyle(.secondary)
                Stepper(title, value: stepped, in: range)
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
