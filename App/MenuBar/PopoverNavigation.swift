import Foundation
import Observation

enum PopoverTab: String, CaseIterable, Identifiable {
    case timer
    case tasks
    case sounds
    case stats

    var id: Self { self }

    var title: String {
        switch self {
        case .timer: "Timer"
        case .tasks: "Tasks"
        case .sounds: "Sounds"
        case .stats: "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .timer: "timer"
        case .tasks: "checklist"
        case .sounds: "waveform"
        case .stats: "chart.bar.fill"
        }
    }
}

/// Which popover tab is showing. It outlives the popover closing, and the app quitting, so the
/// popover reopens where it was left.
@MainActor
@Observable
final class PopoverNavigation {
    static let tabKey = "popover.tab"

    private(set) var tab: PopoverTab
    /// The quick-add text, kept here so it survives the Tasks tab being torn down by a tab switch.
    var quickAddDraft = ""
    /// Whether the quick-add field has focus, so Space types instead of toggling the timer.
    var isEditingTask = false

    /// Space starts or pauses unless it's typing into the quick-add field.
    var spaceTogglesTimer: Bool { !(isEditingTask && tab == .tasks) }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tab = defaults.string(forKey: Self.tabKey).flatMap(PopoverTab.init(rawValue:)) ?? .timer
    }

    func select(_ tab: PopoverTab) {
        guard tab != self.tab else { return }
        self.tab = tab
        // The field leaves with its tab and may not report losing focus on the way out.
        if tab != .tasks { isEditingTask = false }
        defaults.set(tab.rawValue, forKey: Self.tabKey)
    }

    /// The quick-add hotkey: the field lives on the Tasks tab, so that tab comes forward first
    /// and the field takes focus as it appears.
    func showQuickAdd(in model: AppModel) {
        select(.tasks)
        model.requestQuickAddFocus()
    }
}
