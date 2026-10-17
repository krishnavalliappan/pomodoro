import Observation
import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
final class TimelineStoreTests: XCTestCase {
    private let today = CivilDay(year: 2026, month: 10, day: 17)

    /// A time on the harness's day, Saturday 17 October 2026 UTC.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        ModelHarness.utc.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: hour, minute: minute))!
    }

    private func makeTask(_ h: ModelHarness, _ title: String = "Write spec", estimate: Int? = nil) throws -> TaskItem {
        try h.database.tasks.create(title: title, estimatePomodoros: estimate, scheduledDay: today, createdAt: ModelHarness.start)
    }

    @discardableResult
    private func addBlock(_ h: ModelHarness, _ title: String = "Block", at start: Date, minutes: Double = 60, taskID: UUID? = nil) throws -> TimeBlock {
        let block = TimeBlock(taskID: taskID, title: title, start: start, duration: minutes * 60)
        try h.database.blocks.insert(block)
        return block
    }

    private func saved(_ h: ModelHarness) throws -> [TimeBlock] {
        try h.database.blocks.blocks(onDayContaining: ModelHarness.start)
    }

    // MARK: Dropping tasks

    func testDroppingATaskCreatesALinkedBlockSizedByItsEstimate() throws {
        let h = try ModelHarness()
        let task = try makeTask(h, estimate: 2)
        let store = TimelineStore(model: h.makeModel())

        let block = try XCTUnwrap(store.dropTask(task.id, at: at(14, 7)))
        XCTAssertEqual(block.taskID, task.id)
        XCTAssertEqual(block.title, "Write spec")
        XCTAssertEqual(block.start, at(14), "snapped to the quarter hour")
        XCTAssertEqual(block.duration, 2 * 25 * 60, "estimate × the default focus length")
        XCTAssertEqual(try saved(h), [block])
        XCTAssertEqual(store.blocks, [block], "shown before the observation catches up")
        XCTAssertEqual(store.selectedBlockID, block.id)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testDropUsesTheDefaultFocusLength() throws {
        let h = try ModelHarness()
        h.updateDefaultProfile { $0.focusDuration = 50 * 60 }
        let task = try makeTask(h, estimate: 3)
        let store = TimelineStore(model: h.makeModel())
        XCTAssertEqual(store.dropTask(task.id, at: at(9))?.duration, 150 * 60)
    }

    func testDroppingATaskWithoutAnEstimateBlocksHalfAnHour() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let store = TimelineStore(model: h.makeModel())
        XCTAssertEqual(store.dropTask(task.id, at: at(9))?.duration, 30 * 60)
    }

    /// 50 minutes can't end at midnight from a quarter hour; it starts at 23:00, not 23:10.
    func testADropNearMidnightStaysOnTheTimelineAndTheGrid() throws {
        let h = try ModelHarness()
        let task = try makeTask(h, estimate: 2)
        let store = TimelineStore(model: h.makeModel())
        let block = try XCTUnwrap(store.dropTask(task.id, at: at(23, 40)))
        XCTAssertEqual(block.start, at(23))
        XCTAssertEqual(block.end, at(23, 50))
        XCTAssertLessThanOrEqual(block.end, at(0) + 86_400)
    }

    func testDroppingAnUnknownTaskDoesNothing() throws {
        let h = try ModelHarness()
        let store = TimelineStore(model: h.makeModel())
        XCTAssertNil(store.dropTask(UUID(), at: at(9)))
        XCTAssertEqual(try saved(h), [])
        XCTAssertEqual(store.writeCount, 0)
    }

    // MARK: Moving and resizing

    func testMovingWritesOnceOnDrop() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())

        store.dragMove(original.id, by: 20 * 60)
        store.dragMove(original.id, by: 50 * 60)
        XCTAssertEqual(store.blocks.map(\.start), [at(10, 45)], "the preview snaps live")
        XCTAssertEqual(try saved(h), [original], "nothing is written mid-drag")
        XCTAssertEqual(store.writeCount, 0)

        store.endDrag()
        XCTAssertNil(store.drag)
        XCTAssertEqual(try saved(h).map(\.start), [at(10, 45)])
        XCTAssertEqual(try saved(h).map(\.duration), [3600])
        XCTAssertEqual(store.blocks.map(\.start), [at(10, 45)], "no jump back before the observation")
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.selectedBlockID, original.id)
    }

    func testResizingWritesOnceOnDrop() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())

        store.dragResize(original.id, by: 10 * 60)
        store.dragResize(original.id, by: 40 * 60)
        XCTAssertEqual(store.blocks.map(\.duration), [105 * 60])
        XCTAssertEqual(try saved(h), [original])

        store.endDrag()
        XCTAssertEqual(try saved(h).map(\.duration), [105 * 60])
        XCTAssertEqual(try saved(h).map(\.start), [at(10)])
        XCTAssertEqual(store.writeCount, 1)
    }

    func testResizingKeepsAQuarterHour() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())
        store.dragResize(original.id, by: -3 * 3600)
        store.endDrag()
        XCTAssertEqual(try saved(h).map(\.duration), [15 * 60])
    }

    func testResizingAnOffGridBlockKeepsItsEndOnTheGrid() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, "Read", at: at(9, 7))
        let store = TimelineStore(model: h.makeModel())
        store.dragResize(original.id, by: -3600)
        store.endDrag()
        XCTAssertEqual(try saved(h).map(\.start), [at(9, 7)])
        XCTAssertEqual(try saved(h).map(\.end), [at(9, 30)])
    }

    func testResizingABlockTooCloseToMidnightLeavesIt() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, "Late", at: at(23, 50), minutes: 10)
        let store = TimelineStore(model: h.makeModel())
        store.dragResize(original.id, by: 30 * 60)
        store.endDrag()
        XCTAssertEqual(try saved(h), [original])
        XCTAssertEqual(store.writeCount, 0)
    }

    func testADragThatLandsWhereItStartedWritesNothing() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())
        store.dragMove(original.id, by: 5 * 60)
        store.endDrag()
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(try saved(h), [original])
    }

    func testCancellingADragRestoresTheBlock() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())
        store.dragMove(original.id, by: 3600)
        store.cancelDrag()
        store.endDrag()
        XCTAssertEqual(store.blocks, [original])
        XCTAssertEqual(store.writeCount, 0)
    }

    // MARK: Creating

    func testDragCreatingOpensTheEditorAndWritesOnCommit() throws {
        let h = try ModelHarness()
        let store = TimelineStore(model: h.makeModel())

        store.dragCreate(from: at(13, 5), to: at(13, 40))
        store.dragCreate(from: at(13, 5), to: at(14, 20))
        XCTAssertEqual(store.drag?.kind, .create)
        XCTAssertEqual(store.blocks.map(\.start), [at(13)])
        store.endDrag()

        let editor = try XCTUnwrap(store.editor)
        XCTAssertTrue(editor.isNew)
        XCTAssertEqual(editor.block.start, at(13))
        XCTAssertEqual(editor.block.end, at(14, 15))
        XCTAssertEqual(try saved(h), [], "nothing is written until it has a name")

        store.editorTitle = "  Deep work "
        store.commitEditor()
        XCTAssertNil(store.editor)
        let block = try XCTUnwrap(try saved(h).first)
        XCTAssertEqual(block.title, "Deep work")
        XCTAssertEqual(block.start, at(13))
        XCTAssertEqual(block.duration, 75 * 60)
        XCTAssertNil(block.taskID)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testTheEditorCanLinkATask() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let model = h.makeModel()
        let store = TimelineStore(model: model)
        model.tasks.ensureLoaded(task.id)

        store.dragCreate(from: at(13), to: at(14))
        store.endDrag()
        store.setEditorTask(task.id)
        XCTAssertEqual(store.editorTitle, "Write spec", "a blank title takes the task's")
        store.commitEditor()
        XCTAssertEqual(try saved(h).map(\.taskID), [task.id])
        XCTAssertEqual(try saved(h).map(\.title), ["Write spec"])
    }

    func testABlankNewBlockIsDropped() throws {
        let h = try ModelHarness()
        let store = TimelineStore(model: h.makeModel())
        store.dragCreate(from: at(13), to: at(14))
        store.endDrag()
        store.commitEditor()
        XCTAssertEqual(try saved(h), [])
        XCTAssertEqual(store.blocks, [])

        store.dragCreate(from: at(13), to: at(14))
        store.endDrag()
        store.cancelEditor()
        XCTAssertEqual(store.blocks, [])
        XCTAssertEqual(store.writeCount, 0)
    }

    // MARK: Editing

    /// The editor holds the row as it was when the rename began; saving must not put back the
    /// start, length or colour it held then.
    func testSavingARenameKeepsAMoveResizeAndColourMadeMeanwhile() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, "Untitled", at: at(10))
        let store = TimelineStore(model: h.makeModel())

        store.beginRename(original.id)
        store.editorTitle = "Planning"
        store.dragMove(original.id, by: 3600)
        store.endDrag()
        store.dragResize(original.id, by: 30 * 60)
        store.endDrag()
        store.setColor(original.id, "purple")
        XCTAssertEqual(store.editorBlock?.start, at(11), "the editor follows the move")
        store.commitEditor()

        let block = try XCTUnwrap(try saved(h).first)
        XCTAssertEqual(block.title, "Planning")
        XCTAssertEqual(block.start, at(11))
        XCTAssertEqual(block.duration, 90 * 60)
        XCTAssertEqual(block.color, "purple")
        XCTAssertEqual(store.blocks, [block])
    }

    func testSavingARenameKeepsALinkMadeMeanwhile() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let original = try addBlock(h, "Untitled", at: at(10))
        let model = h.makeModel()
        model.tasks.ensureLoaded(task.id)
        let store = TimelineStore(model: model)

        store.beginRename(original.id)
        store.editorTitle = "Planning"
        store.link(original.id, to: task.id)
        store.commitEditor()
        XCTAssertEqual(try saved(h).map(\.taskID), [task.id], "the editor didn't touch the task")
        XCTAssertEqual(try saved(h).map(\.title), ["Planning"])
    }

    func testAnUnchangedRenameWritesNothing() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, "Planning", at: at(10))
        let store = TimelineStore(model: h.makeModel())
        store.beginRename(original.id)
        store.editorTitle = " Planning "
        store.commitEditor()
        XCTAssertEqual(store.writeCount, 0)
    }

    func testRenameLinkUnlinkAndColor() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let original = try addBlock(h, "Untitled", at: at(10))
        let model = h.makeModel()
        model.tasks.ensureLoaded(task.id)
        let store = TimelineStore(model: model)

        store.beginRename(original.id)
        XCTAssertEqual(store.editor?.isNew, false)
        store.editorTitle = "Planning"
        store.commitEditor()
        XCTAssertEqual(try saved(h).map(\.title), ["Planning"])

        store.link(original.id, to: task.id)
        XCTAssertEqual(try saved(h).map(\.taskID), [task.id])
        XCTAssertEqual(store.blocks.map(\.taskID), [task.id])
        store.link(original.id, to: nil)
        XCTAssertEqual(try saved(h).map(\.taskID), [nil])

        store.setColor(original.id, "green")
        XCTAssertEqual(try saved(h).map(\.color), ["green"])
        store.setColor(original.id, "green")
        XCTAssertEqual(store.writeCount, 4, "an unchanged colour isn't written")
    }

    func testDeletingTheSelectedBlock() throws {
        let h = try ModelHarness()
        let doomed = try addBlock(h, at: at(10))
        let kept = try addBlock(h, at: at(12))
        let store = TimelineStore(model: h.makeModel())

        store.deleteSelected()
        XCTAssertEqual(store.writeCount, 0, "nothing selected")
        store.selectedBlockID = doomed.id
        store.deleteSelected()
        XCTAssertNil(store.selectedBlockID)
        XCTAssertEqual(store.blocks, [kept])
        XCTAssertEqual(try saved(h), [kept])
        XCTAssertEqual(store.writeCount, 1)
    }

    // MARK: Focus

    func testPlayStartsFocusOnTheBlocksTask() throws {
        let h = try ModelHarness()
        let seeded = try h.seedTasks()
        let model = h.makeModel()
        let store = TimelineStore(model: model)
        let block = try XCTUnwrap(store.blocks.first { $0.taskID == seeded.reviewPR.id })
        XCTAssertFalse(store.isRunning(block))

        store.startFocus(on: block.id)
        XCTAssertEqual(model.phase, .focus)
        XCTAssertEqual(model.selectedTaskID, seeded.reviewPR.id)
        XCTAssertEqual(model.snapshot.taskID, seeded.reviewPR.id)
        XCTAssertTrue(store.isRunning(block))
    }

    func testPlayOnAnUnlinkedBlockFocusesWithoutATask() throws {
        let h = try ModelHarness()
        let other = try makeTask(h)
        let now = try addBlock(h, "Inbox triage", at: at(8, 30))
        let later = try addBlock(h, "Email", at: at(11))
        let model = h.makeModel()
        model.selectTask(other.id)
        let store = TimelineStore(model: model)

        store.startFocus(on: later.id)
        XCTAssertEqual(model.phase, .focus)
        XCTAssertNil(model.selectedTaskID)
        XCTAssertNil(model.snapshot.taskID)
        XCTAssertTrue(store.isRunning(now), "the unlinked block scheduled now")
        XCTAssertFalse(store.isRunning(later), "not scheduled now")
    }

    /// Starting block A's task, then another task from the sidebar, must not leave A running;
    /// nor may a stop and a later focus on something else bring it back.
    func testRunningFollowsTheEngineAcrossTaskSwitchesAndStops() throws {
        let h = try ModelHarness()
        let a = try makeTask(h, "Task A")
        let b = try makeTask(h, "Task B")
        let blockA = try addBlock(h, "A", at: at(8, 30), taskID: a.id)
        let unlinked = try addBlock(h, "Unlinked", at: at(8, 45))
        let model = h.makeModel()
        let store = TimelineStore(model: model)

        store.startFocus(on: blockA.id)
        XCTAssertTrue(store.isRunning(blockA))
        XCTAssertFalse(store.isRunning(unlinked))

        model.selectTask(b.id)
        XCTAssertFalse(store.isRunning(blockA), "the focus now counts toward B")

        model.selectTask(nil)
        XCTAssertTrue(store.isRunning(unlinked), "a focus without a task runs the unlinked block")
        XCTAssertFalse(store.isRunning(blockA))

        model.stopAndLog()
        XCTAssertFalse(store.isRunning(unlinked))
        XCTAssertFalse(store.isRunning(blockA))

        model.selectTask(b.id)
        model.startFocus()
        XCTAssertFalse(store.isRunning(blockA), "a later focus on B doesn't revive A")

        model.stopAndLog()
        model.startFocus(on: a.id)
        XCTAssertTrue(store.isRunning(blockA))
    }

    func testRunningEndsWhenTheBlockDoesOrMovesAway() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let block = try addBlock(h, at: at(8, 15), taskID: task.id)
        let model = h.makeModel()
        let store = TimelineStore(model: model)
        model.startFocus(on: task.id)
        XCTAssertTrue(store.isRunning(block))

        store.dragMove(block.id, by: 2 * 3600)
        store.endDrag()
        XCTAssertFalse(store.isRunning(try XCTUnwrap(store.blocks.first)), "moved out of now")
        store.dragMove(block.id, by: -2 * 3600)
        store.endDrag()
        XCTAssertTrue(store.isRunning(try XCTUnwrap(store.blocks.first)))

        // The focus runs on, past the block's 09:15 end.
        h.scheduler.advance(by: 20 * 60)
        XCTAssertEqual(model.phase, .focus)
        XCTAssertFalse(store.isRunning(try XCTUnwrap(store.blocks.first)))
    }

    func testTheBlockScheduledNowRunsDuringAFocusOnItsTask() throws {
        let h = try ModelHarness()
        let seeded = try h.seedTasks()
        let later = try addBlock(h, "Later", at: at(15), taskID: seeded.reviewPR.id)
        let model = h.makeModel()
        let store = TimelineStore(model: model)
        model.startFocus(on: seeded.reviewPR.id)
        let current = try XCTUnwrap(store.blocks.first { $0.contains(h.clock.now) })
        XCTAssertTrue(store.isRunning(current))
        XCTAssertFalse(store.isRunning(later))
    }

    // MARK: Observation

    func testObservationFollowsWritesFromElsewhereAndUpdatesTheSuggestion() async throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let model = h.makeModel()
        let store = TimelineStore(model: model)
        let observing = Task { await store.observe() }
        defer { observing.cancel() }
        XCTAssertNil(model.tasks.suggestedTaskID)

        // As quick-add or another window would.
        let block = try addBlock(h, "Write spec", at: at(8, 45), taskID: task.id)
        try await waitUntil { store.blocks == [block] }
        try await waitUntil { model.tasks.suggestedTaskID == task.id }

        store.dragMove(block.id, by: 3 * 3600)
        store.endDrag()
        try await waitUntil { model.tasks.suggestedTaskID == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.blocks.map(\.start), [at(11, 45)], "the observation agrees")
        XCTAssertEqual(store.writeCount, 1)
    }

    // MARK: Writes against newer state

    /// A move, then the linked task deleted elsewhere before the observation catches up: the
    /// timeline must show the unlink, not hold the moved block's old link forever.
    func testAWriteDoesntHideAnUnlinkFromElsewhere() async throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let block = try addBlock(h, at: at(10), taskID: task.id)
        let store = TimelineStore(model: h.makeModel())
        let observing = Task { await store.observe() }
        defer { observing.cancel() }

        store.dragMove(block.id, by: 3600)
        store.endDrag()
        XCTAssertTrue(try h.database.tasks.delete(id: task.id))
        try await waitUntil { store.blocks.map(\.taskID) == [nil] }
        XCTAssertEqual(store.blocks.map(\.start), [at(11)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.blocks.map(\.taskID), [nil], "and it stays unlinked")
    }

    func testAWriteDoesntLeaveAGhostOfABlockDeletedElsewhere() async throws {
        let h = try ModelHarness()
        let block = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())
        let observing = Task { await store.observe() }
        defer { observing.cancel() }

        store.setColor(block.id, "teal")
        XCTAssertTrue(try h.database.blocks.delete(id: block.id))
        try await waitUntil { store.blocks.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.blocks, [])
    }

    /// A value the observation fetched before a write must not put the old block back; one from
    /// a subscription that began after it is current, whatever it says.
    func testValuesFetchedBeforeAWriteAreDropped() throws {
        let h = try ModelHarness()
        let original = try addBlock(h, at: at(10))
        let store = TimelineStore(model: h.makeModel())
        let before = store.writeGeneration

        store.dragMove(original.id, by: 3600)
        store.endDrag()
        XCTAssertFalse(store.receive([original], subscribedAt: before))
        XCTAssertEqual(store.blocks.map(\.start), [at(11)])

        var elsewhere = try XCTUnwrap(try saved(h).first)
        elsewhere.start = at(14)
        XCTAssertTrue(store.receive([elsewhere], subscribedAt: store.writeGeneration))
        XCTAssertEqual(store.blocks, [elsewhere], "newer state from elsewhere wins")
    }

    /// The block was deleted behind the store's back; the move fails, and the timeline shows
    /// what's saved instead of the move.
    func testAFailedMoveShowsWhatIsSaved() throws {
        let h = try ModelHarness()
        let doomed = try addBlock(h, at: at(10))
        let kept = try addBlock(h, at: at(13))
        let store = TimelineStore(model: h.makeModel())
        try h.database.blocks.delete(id: doomed.id)
        let generation = store.writeGeneration

        store.dragMove(doomed.id, by: 3600)
        store.endDrag()
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.writeGeneration, generation, "a failed write fences nothing")
        XCTAssertEqual(try saved(h), [kept])
        XCTAssertEqual(store.blocks, [kept])
        XCTAssertNil(store.selectedBlockID)
    }

    func testAFailedRenameShowsWhatIsSaved() throws {
        let h = try ModelHarness()
        let doomed = try addBlock(h, "Untitled", at: at(10))
        let store = TimelineStore(model: h.makeModel())
        store.beginRename(doomed.id)
        store.editorTitle = "Planning"
        try h.database.blocks.delete(id: doomed.id)
        store.commitEditor()
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(store.blocks, [])
        XCTAssertEqual(try saved(h), [])
    }

    // MARK: Boundaries

    /// Open at 08:59 with a 09:00 block: crossing 09:00 must suggest its task, and crossing its
    /// end must drop it, with no write and no reopening.
    func testTheSuggestionFollowsBlockBoundariesWhileThePopoverIsOpen() throws {
        let h = try ModelHarness()
        h.clock.now = at(8, 59)
        let task = try makeTask(h)
        try addBlock(h, at: at(9), taskID: task.id)
        let model = h.makeModel()
        model.setPopoverVisible(true)
        XCTAssertNil(model.tasks.suggestedTaskID)
        XCTAssertEqual(h.scheduler.pendingDates, [at(9)], "one timer, at the next boundary")

        h.scheduler.advance(by: 60)
        XCTAssertEqual(model.tasks.suggestedTaskID, task.id)
        XCTAssertEqual(model.blockBoundaryTick, 1)
        XCTAssertEqual(h.scheduler.pendingDates, [at(10)])

        h.scheduler.advance(by: 3600)
        XCTAssertNil(model.tasks.suggestedTaskID)
        XCTAssertEqual(h.scheduler.pendingDates, [], "nothing left today")
    }

    func testTheBoundaryTimerRunsOnlyWhileSomethingShowsIt() async throws {
        let h = try ModelHarness()
        try addBlock(h, at: at(10))
        let model = h.makeModel()
        XCTAssertEqual(h.scheduler.pendingDates, [], "popover and planner closed")

        model.setPopoverVisible(true)
        XCTAssertEqual(h.scheduler.pendingDates, [at(10)])
        model.setPopoverVisible(false)
        XCTAssertEqual(h.scheduler.pendingDates, [])

        let store = TimelineStore(model: model)
        let observing = Task { await store.observe() }
        try await waitUntil { h.scheduler.pendingDates == [at(10)] }
        observing.cancel()
        try await waitUntil { h.scheduler.pendingDates.isEmpty }
    }

    /// A block added or moved before the pending boundary reschedules the one timer.
    func testBlockChangesRescheduleTheBoundary() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let block = try addBlock(h, at: at(10))
        let model = h.makeModel()
        model.setPopoverVisible(true)
        let store = TimelineStore(model: model)
        XCTAssertEqual(h.scheduler.pendingDates, [at(10)])

        try XCTUnwrap(store.dropTask(task.id, at: at(9, 30)))
        XCTAssertEqual(h.scheduler.pendingDates, [at(9, 30)])

        store.dragMove(block.id, by: -45 * 60)
        store.endDrag()
        XCTAssertEqual(h.scheduler.pendingDates, [at(9, 15)])

        h.scheduler.advance(by: 15 * 60)
        XCTAssertEqual(store.isRunning(try XCTUnwrap(store.block(id: block.id))), false, "no focus")
        XCTAssertEqual(h.scheduler.pendingDates, [at(9, 30)])
    }

    func testTheRunningHighlightUpdatesAtABlocksStart() throws {
        let h = try ModelHarness()
        let task = try makeTask(h)
        let block = try addBlock(h, at: at(9, 15), taskID: task.id)
        let model = h.makeModel()
        model.setPopoverVisible(true)
        let store = TimelineStore(model: model)
        model.startFocus(on: task.id)
        XCTAssertFalse(store.isRunning(block))

        let invalidated = Flag()
        withObservationTracking { _ = store.isRunning(block) } onChange: { invalidated.set() }
        h.scheduler.advance(by: 15 * 60)
        XCTAssertTrue(invalidated.isSet, "the timeline re-renders at the boundary")
        XCTAssertTrue(store.isRunning(block))
    }

    func testOnlyTheVisibleDayIsShown() throws {
        let h = try ModelHarness()
        let todays = try addBlock(h, at: at(10))
        try addBlock(h, "Tomorrow", at: at(10) + 86_400)
        try addBlock(h, "Before six", at: at(4))
        let store = TimelineStore(model: h.makeModel())
        XCTAssertEqual(store.blocks, [todays])
    }

    func testDayNavigation() throws {
        let h = try ModelHarness()
        let todays = try addBlock(h, at: at(10))
        let tomorrows = try addBlock(h, "Tomorrow", at: at(10) + 86_400)
        let store = TimelineStore(model: h.makeModel())
        XCTAssertTrue(store.isToday)

        store.showNextDay()
        XCTAssertEqual(store.day, CivilDay(year: 2026, month: 10, day: 18))
        XCTAssertFalse(store.isToday)
        XCTAssertEqual(store.blocks, [tomorrows])
        XCTAssertEqual(store.layout.visible.lowerBound, at(6) + 86_400)

        store.showPreviousDay()
        store.showPreviousDay()
        XCTAssertEqual(store.day, CivilDay(year: 2026, month: 10, day: 16))
        XCTAssertEqual(store.blocks, [])

        store.showToday()
        XCTAssertEqual(store.blocks, [todays])
    }

    func testScrollsToAnHourBeforeNowOnToday() throws {
        let h = try ModelHarness()
        let store = TimelineStore(model: h.makeModel())
        XCTAssertEqual(store.initialScrollHour, 2, "08:00, an hour before 09:00")
        store.showNextDay()
        XCTAssertEqual(store.initialScrollHour, 2, "08:00 on an empty day")
    }

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
