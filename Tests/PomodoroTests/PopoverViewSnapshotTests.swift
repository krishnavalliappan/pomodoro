import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class PopoverViewSnapshotTests: XCTestCase {
    private let focus: TimeInterval = 25 * 60

    // MARK: Timer tab

    func testIdle() throws {
        let h = try harness()
        assertPopover(h.makeModel(), .timer, "idle")
    }

    func testFocusRunning() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, .timer, "focus")
    }

    func testPaused() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.clock.advance(by: 6 * 60 + 18)
        model.pause()
        h.clock.advance(by: 60)
        assertPopover(model, .timer, "paused")
    }

    func testOvertimeAwaitingDecision() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus + 135)
        XCTAssertEqual(model.prompt, .focusEnded)
        assertPopover(model, .timer, "overtime")
    }

    func testBreakRunning() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus)
        model.startBreak()
        h.clock.advance(by: 110)
        assertPopover(model, .timer, "break")
    }

    func testBreakOver() throws {
        let h = try harness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus)
        model.startBreak()
        h.scheduler.advance(by: 5 * 60 + 40)
        XCTAssertEqual(model.prompt, .breakEnded)
        assertPopover(model, .timer, "breakOver")
    }

    func testPendingOverride() throws {
        let h = try harness()
        let model = h.makeModel()
        XCTAssertTrue(model.applyOverride("50/10"))
        assertPopover(model, .timer, "override")
    }

    func testPresetOneOff() throws {
        let h = try harness()
        let model = h.makeModel()
        model.toggleOneOffPreset(Preset.deep.id)
        assertPopover(model, .timer, "presetOnce")
    }

    /// A focus on a task: "on <task>" names it.
    func testFocusOnATask() throws {
        let h = try harness()
        let seeded = try h.seedTasks()
        let model = h.makeModel()
        model.startFocus(on: seeded.writeSpec.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, .timer, "task")
    }

    /// No task chosen while a block runs: the block's task is offered under the picker.
    func testScheduledNowSuggestion() throws {
        let h = try harness()
        try h.seedTasks()
        assertPopover(h.makeModel(), .timer, "suggestion")
    }

    /// The title truncates rather than pushing the chevron out.
    func testLongTaskTitleOnTimer() throws {
        let h = try harness()
        let long = try h.seedLongTitle()
        let model = h.makeModel()
        model.startFocus(on: long.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, .timer, "longTitle")
    }

    // MARK: Tasks tab

    /// During a focus on a task: its row is highlighted, and dots show actuals.
    func testTasks() throws {
        let h = try harness()
        let seeded = try h.seedTasks()
        let model = h.makeModel()
        model.startFocus(on: seeded.writeSpec.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, .tasks, "seeded")
    }

    func testNoTasks() throws {
        let h = try harness()
        assertPopover(h.makeModel(), .tasks, "empty")
    }

    /// Typing shows what the parser found, in the line the hint held.
    func testQuickAddPreview() throws {
        let h = try harness()
        try h.seedTasks()
        assertPopover(h.makeModel(), .tasks, "quickAdd", quickAddText: "Write spec ~3 @14:00 45m #work tomorrow")
    }

    func testLongTaskTitleInList() throws {
        let h = try harness()
        let long = try h.seedLongTitle()
        let model = h.makeModel()
        model.startFocus(on: long.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, .tasks, "longTitle")
    }

    // MARK: Sounds and Stats tabs

    func testSoundsPlaceholder() throws {
        let h = try harness()
        assertPopover(h.makeModel(), .sounds, "placeholder")
    }

    /// Uneven days with a gap on Sunday the 11th, and a six-day streak.
    func testStats() throws {
        let h = try ModelHarness(display: .time)
        try h.seedStats()
        assertPopover(h.makeModel(), .stats, "seeded")
    }

    func testStatsEmpty() throws {
        let h = try ModelHarness(display: .time)
        assertPopover(h.makeModel(), .stats, "empty")
    }

    /// Dots up to six, then a count; past the estimate in the overtime color.
    func testEstimateDots() {
        let cases: [(Int?, Int)] = [(3, 1), (2, 3), (nil, 2), (6, 6), (4, 7), (8, 9), (8, 2), (nil, 9)]
        let gallery = VStack(alignment: .trailing, spacing: 6) {
            ForEach(cases.indices, id: \.self) { index in
                let (estimate, actual) = cases[index]
                HStack {
                    Text("\(actual) of \(estimate.map(String.init) ?? "–")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    EstimateDots(estimate: estimate, actual: actual)
                }
            }
        }
        .padding(10)
        .frame(width: 160)
        .background(Color(nsColor: .windowBackgroundColor))
        Snapshot.assertLightAndDark(gallery, size: CGSize(width: 160, height: 200), name: "EstimateDots", variant: "gallery")
    }

    // MARK: - Helpers

    static func freshDefaults() -> UserDefaults {
        let name = "PomodoroTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func harness() throws -> ModelHarness {
        let h = try ModelHarness(display: .time)
        try h.seedCompletedSessions(2)
        return h
    }

    private func assertPopover(
        _ model: AppModel,
        _ tab: PopoverTab,
        _ variant: String,
        quickAddText: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Opening the popover refreshes the readout, as it does in the app.
        model.setPopoverVisible(true)
        let navigation = PopoverNavigation(defaults: Self.freshDefaults())
        navigation.select(tab)
        navigation.quickAddDraft = quickAddText
        let view = PopoverView(model: model, navigation: navigation, actions: PopoverActions(quit: {}))
        // No size: the popover takes the view's own height, as `sizingOptions` makes it do in the app.
        Snapshot.assertLightAndDark(
            view,
            name: "PopoverView",
            variant: "\(tab.rawValue)-\(variant)",
            file: file,
            line: line
        )
    }
}
