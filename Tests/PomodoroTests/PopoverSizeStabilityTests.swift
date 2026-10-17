import AppKit
import SwiftUI
import XCTest
@testable import Pomodoro

/// The popover is content-sized, so its snapshots are only stable if every render measures the
/// same height. Each pass builds a fresh model and view, as a separate test would.
@MainActor
final class PopoverSizeStabilityTests: XCTestCase {
    private let passes = 20

    func testIdleSizeIsStable() throws {
        try assertStableSize { _ in }
    }

    func testTasksSizeIsStable() throws {
        try assertStableSize { try $0.seedTasks() }
    }

    private func assertStableSize(
        seed: (ModelHarness) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var sizes: [String] = []
        for _ in 0..<passes {
            let h = try ModelHarness(display: .time)
            try h.seedCompletedSessions(2)
            try seed(h)
            let model = h.makeModel()
            model.setPopoverVisible(true)
            let view = PopoverView(model: model, actions: PopoverActions(quit: {}), defaults: PopoverViewSnapshotTests.freshDefaults())
            for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
                let size = Snapshot.renderedPixelSize(view, appearance: appearance, scheme: scheme)
                sizes.append("\(Int(size.width))x\(Int(size.height))")
            }
        }
        XCTAssertEqual(Set(sizes).count, 1, "Popover rendered at \(Set(sizes).sorted()) across \(passes) passes: \(sizes)", file: file, line: line)
    }
}
