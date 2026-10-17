import AppKit
import SwiftUI

@main
struct PomodoroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu bar item and windows are AppKit-owned (see MenuBarController and WindowRouter);
        // an app still needs one scene.
        Settings {
            SettingsPlaceholderView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private var menuBar: MenuBarController?
    private let windows = WindowRouter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app; keep them off the real defaults, database and menu bar.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let model = AppModel.live()
        self.model = model
        menuBar = MenuBarController(model: model, windows: windows)
    }
}
