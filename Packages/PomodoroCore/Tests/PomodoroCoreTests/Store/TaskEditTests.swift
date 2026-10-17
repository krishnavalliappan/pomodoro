import Foundation
import Testing
@testable import PomodoroCore

@Suite
struct TaskDraftTests {
    let task = TaskItem(title: "Write spec", notes: "Draft", estimatePomodoros: 2, createdAt: Fixture.date(day: 17))

    @Test func anUntouchedDraftHasNothingToSave() {
        #expect(TaskDraft(task).edit == nil)
    }

    @Test func onlyEditedFieldsAreSaved() {
        var draft = TaskDraft(task)
        draft.title = "  Write the spec "
        #expect(draft.edit == TaskEdit(title: "Write the spec"))
        draft.estimatePomodoros = nil
        #expect(draft.edit == TaskEdit(title: "Write the spec", estimatePomodoros: .some(nil)))
    }

    @Test func aBlankTitleIsNotSaved() {
        var draft = TaskDraft(task)
        draft.title = "   "
        #expect(draft.edit == nil)
    }

    @Test func aCheckOffKeepsTheDirtyTitleAndNotes() {
        var draft = TaskDraft(task)
        draft.title = "Renamed"
        draft.notes = "New notes"
        var done = task
        done.isDone = true
        done.sortIndex = 7
        draft.rebase(onto: done)
        #expect(draft.title == "Renamed")
        #expect(draft.notes == "New notes")
        #expect(draft.edit == TaskEdit(title: "Renamed", notes: "New notes"))
        #expect(draft.edit?.applied(to: done).isDone == true)
    }

    @Test func untouchedFieldsFollowTheRow() {
        var draft = TaskDraft(task)
        draft.title = "Renamed"
        var renamedElsewhere = task
        renamedElsewhere.notes = "From elsewhere"
        renamedElsewhere.estimatePomodoros = 4
        draft.rebase(onto: renamedElsewhere)
        #expect(draft.notes == "From elsewhere")
        #expect(draft.estimatePomodoros == 4)
        #expect(draft.edit == TaskEdit(title: "Renamed"))
    }

    @Test func aSavedEditIsCleanOnceTheRowCatchesUp() {
        var draft = TaskDraft(task)
        draft.title = "Renamed"
        let saved = draft.edit!.applied(to: task)
        draft.rebase(onto: saved)
        #expect(draft.edit == nil)
        #expect(draft.title == "Renamed")
    }
}

@Suite
struct TaskEditMergeTests {
    let db: AppDatabase
    let now = Fixture.date(day: 17, 9)

    init() throws {
        db = try Fixture.database()
    }

    /// The editor's row is stale: the task was rescheduled after it opened. Both changes survive.
    @Test func anEditFromAStaleRowKeepsAConcurrentReschedule() throws {
        let task = try db.tasks.create(title: "Write spec", scheduledDay: Fixture.day(17), createdAt: now)
        var draft = TaskDraft(task)
        draft.title = "Write the spec"
        try db.tasks.schedule(id: task.id, on: Fixture.day(18))

        let saved = try db.tasks.edit(id: task.id, try #require(draft.edit))
        #expect(saved.title == "Write the spec")
        #expect(saved.scheduledDay == Fixture.day(18))
        #expect(try db.tasks.fetch(id: task.id) == saved)
    }

    @Test func anEditKeepsACheckOffAndAReorder() throws {
        let a = try db.tasks.create(title: "A", createdAt: now)
        let b = try db.tasks.create(title: "B", createdAt: now)
        var draft = TaskDraft(a)
        draft.notes = "Notes"
        try db.tasks.setDone(id: a.id, true, at: now)
        try db.tasks.reorder([b.id, a.id])

        let saved = try db.tasks.edit(id: a.id, try #require(draft.edit))
        #expect(saved.notes == "Notes")
        #expect(saved.isDone)
        #expect(saved.doneAt == now)
        #expect(saved.sortIndex == 1)
    }

    @Test func clearingTheEstimate() throws {
        let task = try db.tasks.create(title: "T", estimatePomodoros: 3, createdAt: now)
        let saved = try db.tasks.edit(id: task.id, TaskEdit(estimatePomodoros: .some(nil)))
        #expect(saved.estimatePomodoros == nil)
        #expect(saved.title == "T")
    }

    @Test func editingAMissingTaskThrows() throws {
        let id = UUID()
        #expect(throws: StoreError.notFound(id)) { try db.tasks.edit(id: id, TaskEdit(title: "X")) }
    }
}

@Suite
struct UpcomingByDayTests {
    let db: AppDatabase
    let now = Fixture.date(day: 17, 9)

    init() throws {
        db = try Fixture.database()
    }

    @Test func groupsUpcomingByDaySoonestFirst() throws {
        let later = try db.tasks.create(title: "Later", scheduledDay: Fixture.day(20), createdAt: now)
        let a = try db.tasks.create(title: "A", scheduledDay: Fixture.day(18), createdAt: now)
        let b = try db.tasks.create(title: "B", scheduledDay: Fixture.day(18), createdAt: now)
        let groups = try db.tasks.overview(now: now).upcomingByDay
        #expect(groups.map(\.day) == [Fixture.day(18), Fixture.day(20)])
        #expect(groups.map { $0.tasks.map(\.id) } == [[a.id, b.id], [later.id]])
    }

    /// Reordering one day's tasks leaves the other days where they were.
    @Test func reorderingWithinADayPersists() throws {
        let a = try db.tasks.create(title: "A", scheduledDay: Fixture.day(18), createdAt: now)
        let b = try db.tasks.create(title: "B", scheduledDay: Fixture.day(19), createdAt: now)
        let c = try db.tasks.create(title: "C", scheduledDay: Fixture.day(19), createdAt: now)
        try db.tasks.reorder([c.id, b.id])
        let groups = try db.tasks.overview(now: now).upcomingByDay
        #expect(groups.map { $0.tasks.map(\.id) } == [[a.id], [c.id, b.id]])
    }
}
