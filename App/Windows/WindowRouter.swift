import AppKit
import SwiftUI

/// Opens the app's regular windows from the popover.
///
/// AppKit-managed rather than SwiftUI `Window`/`Settings` scenes: `openWindow` and
/// `SettingsLink` only work from views SwiftUI's scene graph owns, and the popover is hosted
/// by AppKit. As an LSUIElement app, it must also activate itself to bring a window forward.
@MainActor
final class WindowRouter {
    enum Destination: Hashable {
        case planner
        case settings
    }

    /// Set once at launch; the planner shows its tasks.
    var model: AppModel?

    private var windows: [Destination: NSWindow] = [:]

    func show(_ destination: Destination) {
        let window = windows[destination] ?? makeWindow(for: destination)
        windows[destination] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(for destination: Destination) -> NSWindow {
        let window: NSWindow
        switch destination {
        case .planner:
            guard let model else { preconditionFailure("the planner opened before the model existed") }
            window = NSWindow(contentViewController: NSHostingController(rootView: PlannerView(model: model)))
            window.title = "Planner"
            window.styleMask.insert(.resizable)
            window.setContentSize(PlannerView.size)
        case .settings:
            window = NSWindow(contentViewController: NSHostingController(rootView: SettingsPlaceholderView()))
            window.title = "Settings"
            window.setContentSize(SettingsPlaceholderView.size)
        }
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
