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
        try assertStableSize(.timer) { _ in }
    }

    func testTasksSizeIsStable() throws {
        try assertStableSize(.tasks) { try $0.seedTasks() }
    }

    func testStatsSizeIsStable() throws {
        try assertStableSize(.stats) { try $0.seedStats() }
    }

    func testSoundsSizeIsStable() throws {
        try assertStableSize(.sounds) { _ in }
    }

    func testSoundsWithAMixSizeIsStable() throws {
        try assertStableSize(.sounds, seed: { _ in }, prepare: { _, model in
            model.toggleAmbient("rain")
            model.toggleAmbient("fireplace")
        })
    }

    func testSoundsPreviewSizeIsStable() throws {
        try assertStableSize(.sounds, seed: { _ in }, prepare: { _, model in model.tapAmbient("waves") })
    }

    func testOverrideSizeIsStable() throws {
        try assertStableSize(.timer, seed: { _ in }, prepare: { _, model in XCTAssertTrue(model.applyOverride("50/10")) })
    }

    func testDecisionCardSizeIsStable() throws {
        try assertStableSize(.timer, seed: { _ in }, prepare: { h, model in
            model.startFocus()
            h.scheduler.advance(by: 25 * 60 + 135)
            XCTAssertEqual(model.prompt, .focusEnded)
        })
    }

    /// One hosted popover, tabs switched back and forth: the width never moves, and each tab
    /// comes back at the whole-point size it first had.
    func testSwitchingTabsInOnePopoverKeepsEachTabsSize() throws {
        let h = try ModelHarness(display: .time)
        try h.seedCompletedSessions(2)
        try h.seedTasks()
        try h.seedStats()
        let model = h.makeModel()
        model.setPopoverVisible(true)
        let navigation = PopoverNavigation(defaults: PopoverViewSnapshotTests.freshDefaults())
        let host = NSHostingView(rootView: PopoverView(model: model, navigation: navigation, actions: PopoverActions(quit: {})))
        host.appearance = NSAppearance(named: .aqua)

        var first: [PopoverTab: CGSize] = [:]
        for _ in 0..<3 {
            for tab in PopoverTab.allCases {
                navigation.select(tab)
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                XCTAssertEqual(size.width, PopoverView.width, "\(tab)")
                XCTAssertEqual(PopoverView.integralSize(size), PopoverView.integralSize(first[tab] ?? size), "\(tab)")
                first[tab] = first[tab] ?? size
            }
        }
    }

    private func assertStableSize(
        _ tab: PopoverTab,
        seed: (ModelHarness) throws -> Void,
        prepare: (ModelHarness, AppModel) -> Void = { _, _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var sizes: [String] = []
        for _ in 0..<passes {
            let h = try ModelHarness(display: .time)
            try h.seedCompletedSessions(2)
            try seed(h)
            let model = h.makeModel()
            prepare(h, model)
            model.setPopoverVisible(true)
            let navigation = PopoverNavigation(defaults: PopoverViewSnapshotTests.freshDefaults())
            navigation.select(tab)
            let view = PopoverView(model: model, navigation: navigation, actions: PopoverActions(quit: {}))
            for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
                let size = Snapshot.renderedPixelSize(view, appearance: appearance, scheme: scheme)
                sizes.append("\(Int(size.width))x\(Int(size.height))")
            }
        }
        XCTAssertEqual(Set(sizes).count, 1, "Popover rendered at \(Set(sizes).sorted()) across \(passes) passes: \(sizes)", file: file, line: line)
    }
}

/// Every pixel, not just the size: AppKit drew a text field's placeholder a point higher or
/// lower from one render to the next, so snapshots holding an empty field failed at random (#49).
@MainActor
final class PopoverPixelStabilityTests: XCTestCase {
    private let passes = 20

    func testIdleIsPixelStable() throws {
        try assertPixelStable(.timer) { $0.makeModel() }
    }

    func testSuggestionIsPixelStable() throws {
        try assertPixelStable(.timer) { h in
            try h.seedTasks()
            return h.makeModel()
        }
    }

    func testTasksEmptyIsPixelStable() throws {
        try assertPixelStable(.tasks) { $0.makeModel() }
    }

    func testTasksSeededIsPixelStable() throws {
        try assertPixelStable(.tasks) { h in
            let seeded = try h.seedTasks()
            let model = h.makeModel()
            model.startFocus(on: seeded.writeSpec.id)
            h.clock.advance(by: 6 * 60 + 18)
            return model
        }
    }

    /// Typed text is still AppKit's to draw.
    func testQuickAddIsPixelStable() throws {
        try assertPixelStable(.tasks, draft: "Write spec ~3 @14:00 45m #work tomorrow") { h in
            try h.seedTasks()
            return h.makeModel()
        }
    }

    /// Renders as `PopoverViewSnapshotTests` does, from a fresh model each pass, and compares
    /// every pass with the first in the same appearance.
    private func assertPixelStable(
        _ tab: PopoverTab,
        draft: String = "",
        makeModel: (ModelHarness) throws -> AppModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var first: [String: (rep: NSBitmapImageRep, png: Data)] = [:]
        var failures: [String] = []
        for pass in 0..<passes {
            let h = try ModelHarness(display: .time)
            try h.seedCompletedSessions(2)
            let model = try makeModel(h)
            model.setPopoverVisible(true)
            let navigation = PopoverNavigation(defaults: PopoverViewSnapshotTests.freshDefaults())
            navigation.select(tab)
            navigation.quickAddDraft = draft
            let view = PopoverView(model: model, navigation: navigation, actions: PopoverActions(quit: {}))
            for (appearance, scheme, label) in [(NSAppearance.Name.aqua, ColorScheme.light, "light"), (.darkAqua, .dark, "dark")] {
                let rep = try XCTUnwrap(Snapshot.render(view, appearance: appearance, scheme: scheme), file: file, line: line)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), file: file, line: line)
                guard let reference = first[label] else {
                    first[label] = (rep, png)
                    continue
                }
                if png != reference.png {
                    let pixels = Snapshot.differingPixels(rep, reference.rep).map { "\($0) pixels differ" } ?? "size differs"
                    failures.append("pass \(pass) \(label): \(pixels)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(tab) renders differ from the first pass: \(failures)", file: file, line: line)
    }
}
