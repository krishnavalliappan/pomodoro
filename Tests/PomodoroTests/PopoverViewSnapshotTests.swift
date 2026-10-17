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

    func testPresetOneOff() throws {
        let h = try harness()
        let model = h.makeModel()
        model.toggleOneOffPreset(Preset.deep.id)
        assertPopover(model, "presetOnce")
    }

    // MARK: Tasks

    /// A focus on a task: the picker names it, its row is highlighted, and dots show actuals.
    func testFocusOnATask() throws {
        let h = try harness()
        let seeded = try h.seedTasks()
        let model = h.makeModel()
        model.startFocus(on: seeded.writeSpec.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, "tasks")
    }

    func testNoTasks() throws {
        let h = try harness()
        assertPopover(h.makeModel(), "empty")
    }

    /// Typing shows what the parser found; the block running now is offered beside "No task".
    func testQuickAddPreview() throws {
        let h = try harness()
        try h.seedTasks()
        let model = h.makeModel()
        assertPopover(model, "quickAdd", quickAddText: "Write spec ~3 @14:00 45m #work tomorrow")
    }

    /// Folded, the list is just its header and the popover shrinks to fit.
    func testTodayCollapsed() throws {
        let h = try harness()
        try h.seedTasks()
        let defaults = Self.freshDefaults()
        defaults.set(false, forKey: PopoverTaskSection.expandedKey)
        assertPopover(h.makeModel(), "collapsed", defaults: defaults)
    }

    /// The title truncates in the picker and the row rather than pushing the dots out.
    func testLongTaskTitle() throws {
        let h = try harness()
        let long = try h.seedLongTitle()
        let model = h.makeModel()
        model.startFocus(on: long.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertPopover(model, "longTitle")
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
        _ variant: String,
        quickAddText: String = "",
        defaults: UserDefaults = freshDefaults(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Opening the popover refreshes the readout, as it does in the app.
        model.setPopoverVisible(true)
        let view = PopoverView(model: model, actions: PopoverActions(quit: {}), quickAddText: quickAddText, defaults: defaults)
        // The popover takes the view's own height, as `sizingOptions` makes it do in the app.
        let height = NSHostingView(rootView: view).fittingSize.height.rounded(.up)
        Snapshot.assertLightAndDark(
            view,
            size: CGSize(width: PopoverView.width, height: height),
            name: "PopoverView",
            variant: variant,
            file: file,
            line: line
        )
    }
}
