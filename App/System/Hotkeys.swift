import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // No initial shortcuts: any default would clash with some other app, so the user picks.
    static let toggleTimer = Self("toggleTimer")
    static let skipPhase = Self("skipPhase")
    static let openPopover = Self("openPopover")
    static let quickAdd = Self("quickAdd")
}

/// The global shortcuts, in the order Settings lists them.
enum Hotkey: CaseIterable, Identifiable {
    case toggleTimer, skipPhase, openPopover, quickAdd

    var id: Self { self }

    var name: KeyboardShortcuts.Name {
        switch self {
        case .toggleTimer: .toggleTimer
        case .skipPhase: .skipPhase
        case .openPopover: .openPopover
        case .quickAdd: .quickAdd
        }
    }

    var title: String {
        switch self {
        case .toggleTimer: "Start or pause"
        case .skipPhase: "Skip to next phase"
        case .openPopover: "Show or hide timer"
        case .quickAdd: "Quick-add task"
        }
    }
}

/// What each global shortcut does, injected so the wiring can be tested without the menu bar.
struct HotkeyActions {
    var toggleTimer: @MainActor () -> Void
    var skipPhase: @MainActor () -> Void
    var togglePopover: @MainActor () -> Void
    var quickAdd: @MainActor () -> Void

    @MainActor
    func perform(_ hotkey: Hotkey) {
        switch hotkey {
        case .toggleTimer: toggleTimer()
        case .skipPhase: skipPhase()
        case .openPopover: togglePopover()
        case .quickAdd: quickAdd()
        }
    }
}

@MainActor
enum Hotkeys {
    /// Handlers stay inactive until the user records a shortcut in Settings → Shortcuts.
    static func register(_ actions: HotkeyActions) {
        for hotkey in Hotkey.allCases {
            KeyboardShortcuts.onKeyUp(for: hotkey.name) { actions.perform(hotkey) }
        }
    }
}
