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
        var sizes: [CGSize] = []
        var raw: [String] = []
        for _ in 0..<passes {
            let h = try ModelHarness(display: .time)
            try h.seedCompletedSessions(2)
            try seed(h)
            let model = h.makeModel()
            model.setPopoverVisible(true)
            let view = PopoverView(model: model, actions: PopoverActions(quit: {}), defaults: PopoverViewSnapshotTests.freshDefaults())
            raw.append(String(format: "%.6f", NSHostingView(rootView: view).fittingSize.height))
            sizes.append(Snapshot.renderedPixelSize(view, size: Snapshot.fittedSize(of: view)))
        }
        print("PopoverSizeStability raw fitting heights:", raw.joined(separator: " "))
        let distinct = Set(sizes.map { "\(Int($0.width))x\(Int($0.height))" })
        XCTAssertEqual(distinct.count, 1, "Popover rendered at \(distinct.sorted()) across \(passes) passes; raw \(raw)", file: file, line: line)
    }
}
