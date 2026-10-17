import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class PopoverViewSnapshotTests: XCTestCase {
    func testPopoverLight() {
        assertPopover(appearance: .aqua, scheme: .light, name: "light")
    }

    func testPopoverDark() {
        assertPopover(appearance: .darkAqua, scheme: .dark, name: "dark")
    }

    private func assertPopover(
        appearance: NSAppearance.Name,
        scheme: ColorScheme,
        name: String,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let view = NSHostingView(rootView: PopoverView().environment(\.colorScheme, scheme))
        view.appearance = NSAppearance(named: appearance)
        view.frame = CGRect(origin: .zero, size: PopoverView.size)
        view.layoutSubtreeIfNeeded()

        let failure = verifySnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.98),
            named: name,
            snapshotDirectory: Snapshot.directory(for: file),
            file: file,
            testName: "PopoverView",
            line: line
        )
        if let failure {
            XCTFail(failure, file: file, line: line)
        }
    }
}
