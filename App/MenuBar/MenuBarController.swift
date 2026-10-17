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

    /// Focuses the popover's quick-add field. Set by the popover once it has one (#10); until
    /// then the quick-add hotkey just opens the popover.
    var focusQuickAdd: (@MainActor () -> Void)?

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
        let host = NSHostingController(rootView: PopoverView(model: model, actions: actions))
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

    static func symbol(for snapshot: TimerSnapshot) -> String {
        switch snapshot.phase {
        case .idle: return "timer"
        case _ where snapshot.status == .paused: return "pause.circle"
        case .focus: return TimerReadout(snapshot).isOvertime ? "exclamationmark.circle" : "timer.circle.fill"
        case .shortBreak, .longBreak: return "cup.and.saucer.fill"
        }
    }

    // MARK: - Status item

    private func observeStatus() {
        withObservationTracking {
            render(title: model.statusTitle, symbol: Self.symbol(for: model.snapshot))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    private func render(title: String?, symbol: String) {
        guard let button = statusItem.button else { return }
        // The model changes every second while visible; skip AppKit work when the text didn't.
        let key = title ?? "symbol:" + symbol
        guard key != renderedKey else { return }
        renderedKey = key
        if let title {
            button.image = nil
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: Self.titleFont])
        } else {
            button.attributedTitle = NSAttributedString()
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pomodoro")
            image?.isTemplate = true
            button.image = image
        }
    }

    // MARK: - Popover

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func openQuickAdd() {
        if !popover.isShown { showPopover() }
        focusQuickAdd?()
    }

    func showPopover() {
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
