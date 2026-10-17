import AppKit
import SnapshotTesting
import SwiftUI
import XCTest

enum Snapshot {
    /// References live in the repo-level `Snapshots/` folder rather than SnapshotTesting's
    /// default `__Snapshots__`, so CI can upload a single directory for visual QA.
    static func directory(for file: StaticString) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // PomodoroTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Snapshots", isDirectory: true)
            .path
    }

    /// Renders `view` in light and dark, as `<name>.<variant>.light.png` and `….dark.png`.
    @MainActor
    static func assertLightAndDark(
        _ view: some View,
        size: CGSize,
        name: String,
        variant: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appearances: [(NSAppearance.Name, ColorScheme, String)] = [
            (.aqua, .light, "light"),
            (.darkAqua, .dark, "dark"),
        ]
        for (appearance, scheme, label) in appearances {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()

            let failure = verifySnapshot(
                of: host,
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: [variant, label].compactMap { $0 }.joined(separator: "."),
                snapshotDirectory: directory(for: file),
                file: file,
                testName: name,
                line: line
            )
            if let failure {
                XCTFail(failure, file: file, line: line)
            }
        }
    }
}
