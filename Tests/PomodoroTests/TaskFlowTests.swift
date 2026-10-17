import AppKit
import Observation
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

    func testATaskDeletedElsewhereStillLogsItsTimeUnlinked() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Doomed"))
        model.startFocus(on: task.id)
        h.scheduler.advance(by: 300)
        // Straight through the repository, so the selection still names the task.
        try h.database.tasks.delete(id: task.id)
        h.scheduler.advance(by: 300)
        model.stopAndLog()

        let sessions = try h.sessionsToday()
        XCTAssertEqual(sessions.count, 1, "the time is kept")
        XCTAssertNil(sessions.first?.taskID)
        XCTAssertEqual(sessions.first?.activeSeconds ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(sessions.first?.start, ModelHarness.start)
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

    // MARK: Editing

    /// The editor opened on the old row; the task was rescheduled before the title was saved.
    func testAnEditFromAStaleEditorKeepsAReschedule() async throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        var draft = TaskDraft(task)
        draft.title = "Write the spec"
        model.tasks.schedule(task.id, on: tomorrow)
        model.tasks.edit(task.id, try XCTUnwrap(draft.edit))

        let stored = try XCTUnwrap(try h.database.tasks.fetch(id: task.id))
        XCTAssertEqual(stored.title, "Write the spec")
        XCTAssertEqual(stored.scheduledDay, tomorrow)
        try await waitUntil { model.tasks.overview.upcoming.map(\.title) == ["Write the spec"] }
        XCTAssertEqual(model.tasks.overview.today, [])
    }

    /// Dirty title and notes ride out a check-off and a reorder, and all three are saved.
    func testADirtyDraftSurvivesACheckOffAndAReorder() async throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("A"))
        let other = try XCTUnwrap(model.addTask("B"))
        try await waitUntil { model.tasks.overview.today.count == 2 }
        var draft = TaskDraft(try XCTUnwrap(model.tasks.task(id: task.id)))
        draft.title = "A, renamed"
        draft.notes = "Some notes"

        model.tasks.setDone(task.id, true)
        try await waitUntil { model.tasks.task(id: task.id)?.isDone == true }
        draft.rebase(onto: try XCTUnwrap(model.tasks.task(id: task.id)))
        model.tasks.reorder([other.id, task.id])
        draft.rebase(onto: try XCTUnwrap(model.tasks.task(id: task.id)))
        XCTAssertEqual(draft.title, "A, renamed")
        XCTAssertEqual(draft.notes, "Some notes")

        model.tasks.edit(task.id, try XCTUnwrap(draft.edit))
        let stored = try XCTUnwrap(try h.database.tasks.fetch(id: task.id))
        XCTAssertEqual(stored.title, "A, renamed")
        XCTAssertEqual(stored.notes, "Some notes")
        XCTAssertTrue(stored.isDone)
        XCTAssertEqual(try h.database.tasks.today(now: h.clock.now).map(\.id), [other.id, task.id])
    }

    /// Paused, nothing ticks, so the menu bar only learns of a rename through observation.
    func testRenamingThePausedTaskRefreshesTheMenuBarTitle() throws {
        let h = try ModelHarness(display: .timeAndTask)
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        model.startFocus(on: task.id)
        h.scheduler.advance(by: 60)
        model.pause()
        XCTAssertEqual(model.statusTitle, "⏸ 24:00 · Write spec")
        let fired = h.scheduler.firedCount

        let invalidated = Flag()
        withObservationTracking { _ = model.statusTitle } onChange: { invalidated.set() }
        model.tasks.edit(task.id, TaskEdit(title: "Review spec"))
        XCTAssertTrue(invalidated.isSet)
        XCTAssertEqual(model.statusTitle, "⏸ 24:00 · Review spec")
        XCTAssertEqual(h.scheduler.firedCount, fired, "no tick involved")
    }

    func testARenameFromElsewhereRefreshesTheMenuBarTitle() async throws {
        let h = try ModelHarness(display: .timeAndTask)
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write spec"))
        try await waitUntil { model.tasks.overview.today.count == 1 }
        model.startFocus(on: task.id)
        model.pause()

        let invalidated = Flag()
        withObservationTracking { _ = model.statusTitle } onChange: { invalidated.set() }
        try h.database.tasks.edit(id: task.id, TaskEdit(title: "Review spec"))
        try await waitUntil { invalidated.isSet }
        XCTAssertEqual(model.statusTitle, "⏸ 25:00 · Review spec")
    }

    // MARK: Upcoming

    /// Each day reorders on its own; other days keep their place in the list and after a reload.
    func testUpcomingReordersWithinADay() async throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let later = CivilDay(year: 2026, month: 10, day: 19)
        let a = try h.database.tasks.create(title: "A", scheduledDay: tomorrow, createdAt: h.clock.now)
        let b = try h.database.tasks.create(title: "B", scheduledDay: later, createdAt: h.clock.now)
        let c = try h.database.tasks.create(title: "C", scheduledDay: later, createdAt: h.clock.now)
        try await waitUntil { model.tasks.overview.upcoming.count == 3 }

        model.tasks.reorder([c.id, b.id])
        XCTAssertEqual(model.tasks.overview.upcoming.map(\.id), [a.id, c.id, b.id], "applied at once, A stays first")
        XCTAssertEqual(model.tasks.overview.upcomingByDay.map(\.day), [tomorrow, later])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.tasks.overview.upcoming.map(\.id), [a.id, c.id, b.id], "the observation agrees")
        XCTAssertEqual(h.makeModel().tasks.overview.upcoming.map(\.id), [a.id, c.id, b.id], "and a reload")
    }

    // MARK: Popover list

    func testMoreInPlannerCountsOnlyHiddenOpenTasks() {
        func tasks(open: Int, done: Int) -> [TaskItem] {
            (0..<open).map { TaskItem(title: "Open \($0)", createdAt: ModelHarness.start) }
                + (0..<done).map { TaskItem(title: "Done \($0)", isDone: true, createdAt: ModelHarness.start) }
        }
        XCTAssertEqual(PopoverTaskSection.hiddenOpenCount(tasks(open: 5, done: 2)), 0)
        XCTAssertEqual(PopoverTaskSection.hiddenOpenCount(tasks(open: 4, done: 3)), 0)
        XCTAssertEqual(PopoverTaskSection.hiddenOpenCount(tasks(open: 7, done: 1)), 2)
    }

    func testOverflowingDotsBecomeACount() {
        XCTAssertEqual(EstimateDots(estimate: 4, actual: 7).countText, "7/4")
        XCTAssertEqual(EstimateDots(estimate: nil, actual: 9).countText, "9")
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

    /// Set from an observation's `onChange`, which may run off the main actor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

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
