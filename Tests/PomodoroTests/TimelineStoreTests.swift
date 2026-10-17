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

    func testADropNearMidnightStaysOnTheTimeline() throws {
        let h = try ModelHarness()
        let task = try makeTask(h, estimate: 2)
        let store = TimelineStore(model: h.makeModel())
        let block = try XCTUnwrap(store.dropTask(task.id, at: at(23, 40)))
        XCTAssertEqual(block.end, at(0) + 86_400)
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
        let block = try addBlock(h, "Inbox triage", at: at(11))
        let model = h.makeModel()
        model.selectTask(other.id)
        let store = TimelineStore(model: model)

        store.startFocus(on: block.id)
        XCTAssertEqual(model.phase, .focus)
        XCTAssertNil(model.selectedTaskID)
        XCTAssertNil(model.snapshot.taskID)
        XCTAssertTrue(store.isRunning(block), "highlighted although it isn't scheduled now")
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
