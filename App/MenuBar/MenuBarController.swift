import AppKit
import Observation
import PomodoroCore
import SwiftUI

/// Owns the `NSStatusItem` and its popover.
///
/// AppKit rather than `MenuBarExtra`: the title changes every second, and here that's one
/// attributed-string assignment with a monospaced-digit font, rather than a SwiftUI label
/// re-render whose font modifiers the menu bar may ignore. `NSPopover` also reports when it
/// opens and closes, which gates the per-second refresh; `MenuBarExtra` exposes neither.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let windows: WindowRouter
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var renderedKey: String?

    init(model: AppModel, windows: WindowRouter) {
        self.model = model
        self.windows = windows
        super.init()

        popover.behavior = .transient
        popover.delegate = self
        let actions = PopoverActions(
            openPlanner: { [weak self] in self?.open(.planner) },
            openSettings: { [weak self] in self?.open(.settings) }
        )
        let host = PopoverHostingController(rootView: PopoverView(model: model, actions: actions))
        // The popover follows the view's height as the task list folds, empties or fills.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("Pomodoro")
        }
        observeStatus()
    }

    static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)

    /// Opt-in: draw the tomato glyph beside the time instead of the 🍅/☕ emoji. Read from
    /// defaults so Settings can expose it without this file depending on the settings model.
    static let glyphBesideTimeKey = "menuBarGlyphBesideTime"

    enum Icon: Equatable {
        case tomato
        case symbol(String)

        var image: NSImage? {
            let image = switch self {
            case .tomato: NSImage(named: "MenuBarIcon")
            case .symbol(let name): NSImage(systemSymbolName: name, accessibilityDescription: "Pomodoro")
            }
            image?.isTemplate = true
            return image
        }
    }

    static func icon(for snapshot: TimerSnapshot) -> Icon {
        switch snapshot.phase {
        case .idle: return .tomato
        case _ where snapshot.status == .paused: return .symbol("pause.circle")
        case .focus: return TimerReadout(snapshot).isOvertime ? .symbol("exclamationmark.circle") : .tomato
        case .shortBreak, .longBreak: return .symbol("cup.and.saucer.fill")
        }
    }

    /// SF Symbol names for `MenuBarSettingsView`'s preview, which predates the asset glyph.
    static func symbol(for snapshot: TimerSnapshot) -> String {
        switch icon(for: snapshot) {
        case .tomato: return snapshot.phase == .idle ? "timer" : "timer.circle.fill"
        case .symbol(let name): return name
        }
    }

    /// Swaps the title's leading emoji for a template image, so the glyph follows the menu bar's tint.
    static func glyphTitle(_ title: String) -> (icon: Icon?, text: String) {
        for (emoji, icon) in [("🍅 ", Icon.tomato), ("☕ ", Icon.symbol("cup.and.saucer.fill"))] where title.hasPrefix(emoji) {
            return (icon, String(title.dropFirst(emoji.count)))
        }
        return (nil, title)
    }

    /// Styles a status bar button; static so snapshot tests can render a plain `NSButton` the same way.
    static func apply(title: String?, icon: Icon, glyphBesideTime: Bool, to button: NSButton) {
        if let title {
            let (glyph, text) = glyphBesideTime ? glyphTitle(title) : (nil, title)
            button.image = glyph?.image
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: titleFont])
        } else {
            button.attributedTitle = NSAttributedString()
            button.image = icon.image
            button.imagePosition = .imageOnly
        }
    }

    // MARK: - Status item

    private func observeStatus() {
        withObservationTracking {
            render(title: model.statusTitle, icon: Self.icon(for: model.snapshot))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    private func render(title: String?, icon: Icon) {
        guard let button = statusItem.button else { return }
        let glyphBesideTime = UserDefaults.standard.bool(forKey: Self.glyphBesideTimeKey)
        // The model changes every second while visible; skip AppKit work when the output didn't.
        let key = "\(title ?? "")|\(icon)|\(glyphBesideTime)"
        guard key != renderedKey else { return }
        renderedKey = key
        Self.apply(title: title, icon: icon, glyphBesideTime: glyphBesideTime, to: button)
    }

    // MARK: - Popover

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// The quick-add hotkey. The field sits above the Today list, so it's there even when the
    /// list is folded.
    func focusQuickAdd() {
        if !popover.isShown { showPopover() }
        model.requestQuickAddFocus()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // LSUIElement apps aren't active by default; without this the popover gets no keystrokes.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func open(_ destination: WindowRouter.Destination) {
        popover.performClose(nil)
        windows.show(destination)
    }

    func popoverWillShow(_ notification: Notification) {
        model.setPopoverVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPopoverVisible(false)
    }
}

/// Reports a whole-point size, so the live popover is exactly as tall as its snapshots.
private final class PopoverHostingController: NSHostingController<PopoverView> {
    override var preferredContentSize: NSSize {
        get { PopoverView.integralSize(super.preferredContentSize) }
        set { super.preferredContentSize = newValue }
    }
}
