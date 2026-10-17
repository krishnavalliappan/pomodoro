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
        /// The planner window, on its Stats tab.
        case stats
        case settings
    }

    private let model: AppModel
    private let launchAtLogin: LaunchAtLogin
    private var windows: [Destination: NSWindow] = [:]
    /// The planner window's tab, kept here so the popover's buttons can pick it.
    let plannerRoute = PlannerRoute()

    init(model: AppModel, launchAtLogin: LaunchAtLogin) {
        self.model = model
        self.launchAtLogin = launchAtLogin
    }

    func show(_ destination: Destination) {
        switch destination {
        case .planner: plannerRoute.tab = .plan
        case .stats: plannerRoute.tab = .stats
        case .settings: break
        }
        // Plan and Stats share one window.
        let key = destination == .stats ? Destination.planner : destination
        let window = windows[key] ?? makeWindow(for: key)
        windows[key] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(for destination: Destination) -> NSWindow {
        let window: NSWindow
        switch destination {
        case .planner, .stats:
            window = NSWindow(contentViewController: NSHostingController(rootView: PlannerWindow(model: model, route: plannerRoute)))
            window.title = "Planner"
            window.styleMask.insert(.resizable)
            window.setContentSize(PlannerWindow.size)
        case .settings:
            window = SettingsWindow.make(model: model, launchAtLogin: launchAtLogin)
        }
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
