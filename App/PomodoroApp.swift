import AppKit
import SwiftUI

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item and windows are AppKit-owned (see MenuBarController and WindowRouter);
        // an app still needs one scene.
        Settings {
            EmptyView()
        }
        .commands {
            // The scene's own Settings item would open the empty window above.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private var services: AppServices?
    private var menuBar: MenuBarController?
    private var windows: WindowRouter?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; keep them off the real defaults, database, notifications and menu bar.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Before launch finishes: a cold launch from a notification action delivers its response
        // right after, and it's lost if the notification delegate isn't installed yet.
        let services = AppServices.live()
        self.services = services
        model = services.model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let windows = WindowRouter(model: model, launchAtLogin: LaunchAtLogin(model: model))
        self.windows = windows
        let menuBar = MenuBarController(model: model, windows: windows)
        self.menuBar = menuBar
        Hotkeys.register(HotkeyActions(
            toggleTimer: { [weak model] in model?.toggle() },
            skipPhase: { [weak model] in model?.skip() },
            togglePopover: { [weak menuBar] in menuBar?.togglePopover(nil) },
            quickAdd: { [weak menuBar] in menuBar?.focusQuickAdd() }
        ))
    }

    func showSettings() {
        windows?.show(.settings)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
