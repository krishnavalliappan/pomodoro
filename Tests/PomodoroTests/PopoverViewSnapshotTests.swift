import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class PopoverViewSnapshotTests: XCTestCase {
    private let focus: TimeInterval = 25 * 60

    func testIdle() throws {
        let h = try harness()
        assertPopover(h.makeModel(), "idle")
    }

    func testFocusRunning() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, "focus")
    }

    func testPaused() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.clock.advance(by: 6 * 60 + 18)
        model.pause()
        h.clock.advance(by: 60)
        assertPopover(model, "paused")
    }

    func testOvertimeAwaitingDecision() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus + 135)
        XCTAssertEqual(model.prompt, .focusEnded)
        assertPopover(model, "overtime")
    }

    func testBreakRunning() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus)
        model.startBreak()
        h.clock.advance(by: 110)
        assertPopover(model, "break")
    }

    func testBreakOver() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus)
        model.startBreak()
        h.scheduler.advance(by: 5 * 60 + 40)
        XCTAssertEqual(model.prompt, .breakEnded)
        assertPopover(model, "breakOver")
    }

    func testPendingOverride() throws {
        let h = try harness()
        let model = h.makeModel()
        XCTAssertTrue(model.applyOverride("50/10"))
        assertPopover(model, "override")
    }

    func testPlaceholderWindows() {
        Snapshot.assertLightAndDark(PlannerPlaceholderView(), size: PlannerPlaceholderView.size, name: "PlannerPlaceholderView")
        Snapshot.assertLightAndDark(SettingsPlaceholderView(), size: SettingsPlaceholderView.size, name: "SettingsPlaceholderView")
    }

    // MARK: - Helpers

    private func harness() throws -> ModelHarness {
        let h = try ModelHarness(display: .time)
        try h.seedCompletedSessions(2)
        return h
    }

    private func assertPopover(_ model: AppModel, _ variant: String, file: StaticString = #filePath, line: UInt = #line) {
        // Opening the popover refreshes the readout, as it does in the app.
        model.setPopoverVisible(true)
        Snapshot.assertLightAndDark(
            PopoverView(model: model, actions: PopoverActions(quit: {})),
            size: PopoverView.size,
            name: "PopoverView",
            variant: variant,
            file: file,
            line: line
        )
    }
}
