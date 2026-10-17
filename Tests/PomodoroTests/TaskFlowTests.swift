import AppKit
import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
final class TaskFlowTests: XCTestCase {
    private let focus: TimeInterval = 25 * 60
    private let today = CivilDay(year: 2026, month: 10, day: 17)
    private let tomorrow = CivilDay(year: 2026, month: 10, day: 18)

    // MARK: Quick-add

    func testQuickAddCreatesATaskForToday() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec ~3 #work"))
        XCTAssertEqual(task.title, "Write spec")
        XCTAssertEqual(task.estimatePomodoros, 3)
        XCTAssertEqual(task.tag, "work")
        XCTAssertEqual(task.scheduledDay, today)
        XCTAssertEqual(try h.database.tasks.today(now: h.clock.now).map(\.id), [task.id])
        XCTAssertEqual(try h.database.blocks.blocks(onDayContaining: h.clock.now), [])
    }

    func testQuickAddWithAStartTimeAlsoBlocksTime() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Review PR ~2 @14:00"))
        let block = try XCTUnwrap(h.database.blocks.block(at: ModelHarness.start + 5 * 3600 + 60))
        XCTAssertEqual(block.taskID, task.id)
        XCTAssertEqual(block.title, "Review PR")
        XCTAssertEqual(block.start, ModelHarness.start + 5 * 3600, "14:00 UTC")
        XCTAssertEqual(block.duration, 2 * focus, "sized by the estimate")
    }

    func testQuickAddFollowsTheParsedDayAndTheInboxDefault() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        XCTAssertEqual(model.addTask("Plan trip tomorrow")?.scheduledDay, tomorrow)
        XCTAssertNil(model.addTask("Someday", toInbox: true)?.scheduledDay)
    }

    func testQuickAddUsesTheDefaultFocusLengthForBlocks() throws {
        let h = try ModelHarness()
        h.updateDefaultProfile { $0.focusDuration = 50 * 60 }
        let model = h.makeModel()
        XCTAssertEqual(model.parseQuickAdd("Deep work ~2 @10:00").blockDuration, 100 * 60)
    }

    func testQuickAddIgnoresAnEmptyTitle() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        XCTAssertNil(model.addTask(""))
        XCTAssertNil(model.addTask("   "))
        XCTAssertNil(model.addTask("~2 @14:00 #work"))
        XCTAssertEqual(try h.database.tasks.all(), [])
        XCTAssertEqual(try h.database.blocks.blocks(onDayContaining: h.clock.now), [])
    }

    func testQuickAddPreviewChips() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let result = model.parseQuickAdd("Write spec ~3 @14:00 45m #work tomorrow")
        XCTAssertEqual(
            QuickAddPreview.chips(for: result, today: today, calendar: ModelHarness.utc),
            ["~3", "14:00", "45m", "#work", "tomorrow"]
        )
        XCTAssertEqual(QuickAddPreview.chips(for: model.parseQuickAdd("Plain"), today: today, calendar: ModelHarness.utc), [])
        XCTAssertEqual(QuickAddPreview.durationText(90 * 60), "1h30m")
        XCTAssertEqual(QuickAddPreview.durationText(2 * 3600), "2h")
        XCTAssertEqual(QuickAddPreview.dayText(CivilDay(year: 2026, month: 10, day: 20), today: today, calendar: ModelHarness.utc), "Tue")
    }

    // MARK: Starting on a task

    func testCompletedSessionRecordsItsTask() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        model.startFocus(on: task.id)
        XCTAssertEqual(model.selectedTaskID, task.id)
        XCTAssertEqual(model.currentTaskTitle, "Write spec")
        h.scheduler.advance(by: focus + 30)
        model.startBreak()

        let session = try XCTUnwrap(h.sessionsToday().first)
        XCTAssertEqual(session.taskID, task.id)
        XCTAssertTrue(session.completed)
        XCTAssertEqual(try h.database.sessions.actuals(forTask: task.id).completedPomodoros, 1)
    }

    func testStoppedSessionRecordsItsTask() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        model.startFocus(on: task.id)
        h.scheduler.advance(by: 600)
        model.stopAndLog()

        let session = try XCTUnwrap(h.sessionsToday().first)
        XCTAssertEqual(session.taskID, task.id)
        XCTAssertFalse(session.completed)
        XCTAssertEqual(session.activeSeconds, 600, accuracy: 0.001)
    }

    func testSelectionOutlivesAStopAndStartsTheNextFocus() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        model.selectTask(task.id)
        XCTAssertEqual(model.snapshot.phase, .idle, "picking a task doesn't start one")
        model.startFocus()
        XCTAssertEqual(model.snapshot.taskID, task.id)
        model.stopAndLog()
        model.toggle()
        XCTAssertEqual(model.snapshot.taskID, task.id)
    }

    func testSwitchingTasksMidSessionReattributesIt() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let first = try XCTUnwrap(model.addTask("First"))
        let second = try XCTUnwrap(model.addTask("Second"))
        model.startFocus(on: first.id)
        h.scheduler.advance(by: 300)
        model.selectTask(second.id)
        XCTAssertEqual(model.snapshot.taskID, second.id)
        XCTAssertEqual(model.snapshot.elapsed, 300, accuracy: 0.001, "the timer keeps running")
        XCTAssertEqual(h.timerStore.load()?.state.taskID, second.id, "persisted for a relaunch")
        h.scheduler.advance(by: 300)
        model.stopAndLog()

        let sessions = try h.sessionsToday()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.taskID, second.id)
    }

    func testPlayOnAnotherTaskDuringAFocusSwitchesInsteadOfRestarting() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let first = try XCTUnwrap(model.addTask("First"))
        let second = try XCTUnwrap(model.addTask("Second"))
        model.startFocus(on: first.id)
        h.scheduler.advance(by: 120)
        model.startFocus(on: second.id)
        XCTAssertEqual(model.snapshot.elapsed, 120, accuracy: 0.001)
        XCTAssertEqual(model.snapshot.taskID, second.id)
        XCTAssertEqual(try h.sessionsToday(), [], "nothing logged by the switch")
    }

    func testPlayDuringABreakStartsAFocusOnTheTask() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Next"))
        model.startFocus()
        h.scheduler.advance(by: focus)
        model.startBreak()
        model.startFocus(on: task.id)
        XCTAssertEqual(model.snapshot.phase, .focus)
        XCTAssertEqual(model.snapshot.taskID, task.id)
    }

    func testRelaunchRestoresTheRunningTask() throws {
        let h = try ModelHarness()
        let task = try XCTUnwrap(h.makeModel().addTask("Write spec"))
        let first = h.makeModel()
        first.startFocus(on: task.id)
        first.shutdown()

        let relaunched = h.makeModel()
        XCTAssertEqual(relaunched.selectedTaskID, task.id)
        XCTAssertEqual(relaunched.currentTaskTitle, "Write spec")
    }

    func testDeletingTheCurrentTaskKeepsTheSessionUnlinked() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Doomed"))
        model.startFocus(on: task.id)
        h.scheduler.advance(by: 300)
        model.deleteTask(task.id)
        XCTAssertNil(model.selectedTaskID)
        h.scheduler.advance(by: 300)
        model.stopAndLog()

        let sessions = try h.sessionsToday()
        XCTAssertEqual(sessions.count, 1, "the time is kept")
        XCTAssertNil(sessions.first?.taskID)
    }

    func testStatusTitleShowsTheTask() throws {
        let h = try ModelHarness(display: .timeAndTask)
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        model.startFocus(on: task.id)
        XCTAssertEqual(model.statusTitle, "🍅 25:00 · Write spec")
    }

    // MARK: Live updates

    func testActualsUpdateLiveWhenASessionIsLogged() async throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec ~2"))
        try await waitUntil { model.tasks.overview.today.map(\.id) == [task.id] }
        XCTAssertEqual(model.tasks.actuals(for: task.id), .zero)

        model.startFocus(on: task.id)
        h.scheduler.advance(by: focus)
        model.startBreak()
        try await waitUntil { model.tasks.actuals(for: task.id).completedPomodoros == 1 }
    }

    func testCheckingOffUpdatesTheList() async throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let a = try XCTUnwrap(model.addTask("A"))
        let b = try XCTUnwrap(model.addTask("B"))
        try await waitUntil { model.tasks.overview.today.count == 2 }
        model.tasks.setDone(a.id, true)
        try await waitUntil { model.tasks.todayByStatus.map(\.id) == [b.id, a.id] }
    }

    func testReorderIsAppliedAtOnceAndPersisted() async throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let a = try XCTUnwrap(model.addTask("A"))
        let b = try XCTUnwrap(model.addTask("B"))
        let c = try XCTUnwrap(model.addTask("C"))
        try await waitUntil { model.tasks.overview.today.count == 3 }
        model.tasks.reorder([c.id, a.id, b.id])
        XCTAssertEqual(model.tasks.overview.today.map(\.id), [c.id, a.id, b.id], "no wait for the database")
        XCTAssertEqual(try h.database.tasks.today(now: h.clock.now).map(\.id), [c.id, a.id, b.id])
    }

    // MARK: Block suggestion

    func testTheCurrentBlocksTaskIsSuggested() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Review PR"))
        try h.database.blocks.insert(TimeBlock(taskID: task.id, title: "Review PR", start: ModelHarness.start - 600, duration: 3600))
        XCTAssertNil(model.tasks.suggestedTaskID, "only looked up when the popover opens")
        model.setPopoverVisible(true)
        XCTAssertEqual(model.tasks.suggestedTaskID, task.id)

        model.setPopoverVisible(false)
        h.clock.advance(by: 3600)
        model.setPopoverVisible(true)
        XCTAssertNil(model.tasks.suggestedTaskID, "the block has ended")
    }

    func testABlockWithoutATaskSuggestsNothing() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        try h.database.blocks.insert(TimeBlock(title: "Lunch", start: ModelHarness.start, duration: 3600))
        model.setPopoverVisible(true)
        XCTAssertNil(model.tasks.suggestedTaskID)
    }

    // MARK: Day rollover

    func testMidnightRollsTheListsOverToTheNewDay() async throws {
        let h = try ModelHarness()
        let center = NotificationCenter()
        let model = h.makeModel()
        model.observeDayChanges(center: center, workspaceCenter: NotificationCenter())
        let planned = try h.database.tasks.create(title: "Tomorrow's", scheduledDay: tomorrow, createdAt: h.clock.now)
        try await waitUntil { model.tasks.overview.upcoming.map(\.id) == [planned.id] }
        XCTAssertEqual(model.tasks.overview.today, [])
        let generation = model.tasks.generation

        h.clock.now = ModelHarness.utc.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 0, second: 1))!
        center.post(name: .NSCalendarDayChanged, object: nil)
        try await waitUntil { model.tasks.overview.day == self.tomorrow }
        XCTAssertEqual(model.tasks.generation, generation + 1, "re-subscribed")
        XCTAssertEqual(model.tasks.overview.today.map(\.id), [planned.id])

        // The new subscription watches the new day.
        let later = try h.database.tasks.create(title: "Added after midnight", scheduledDay: tomorrow, createdAt: h.clock.now)
        try await waitUntil { model.tasks.overview.today.map(\.id) == [planned.id, later.id] }
    }

    func testWakeOnALaterDayRollsOver() async throws {
        let h = try ModelHarness()
        let workspace = NotificationCenter()
        let model = h.makeModel()
        model.observeDayChanges(center: NotificationCenter(), workspaceCenter: workspace)
        h.clock.advance(by: 86_400)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitUntil { model.tasks.overview.day == self.tomorrow }
    }

    func testWakeOnTheSameDayKeepsTheSubscription() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let generation = model.tasks.generation
        h.clock.advance(by: 3600)
        model.dayMayHaveChanged(.woke)
        XCTAssertEqual(model.tasks.generation, generation)
        model.dayMayHaveChanged(.timeZoneChanged)
        XCTAssertEqual(model.tasks.generation, generation + 1, "a time-zone change always re-subscribes")
    }

    func testRolloverRefreshesTodaysCount() throws {
        let h = try ModelHarness()
        try h.seedCompletedSessions(2)
        let model = h.makeModel()
        XCTAssertEqual(model.completedToday, 2)
        h.clock.advance(by: 86_400)
        model.dayMayHaveChanged(.dayChanged)
        XCTAssertEqual(model.completedToday, 0)
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date() + timeout
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met within \(timeout)s", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
