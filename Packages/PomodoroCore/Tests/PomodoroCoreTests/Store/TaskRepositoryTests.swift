import Foundation
import Testing
@testable import PomodoroCore

// Observation tests await stream values; fail fast instead of hanging CI if one never arrives.
@Suite(.timeLimit(.minutes(1)))
struct TaskRepositoryTests {
    let db: AppDatabase
    let now = Fixture.date(day: 17, 14, 30)

    init() throws {
        db = try Fixture.database()
    }

    @Test func createAppendsToEndAndRoundTrips() throws {
        let a = try db.tasks.create(title: "A", createdAt: now)
        let b = try db.tasks.create(
            title: "B", notes: "details", estimatePomodoros: 3, tag: "work",
            scheduledDay: Fixture.date(day: 18, 15, 45), createdAt: now
        )
        #expect(a.sortIndex == 0)
        #expect(b.sortIndex == 1)
        #expect(b.scheduledDay == Fixture.date(day: 18))

        let fetched = try #require(try db.tasks.fetch(id: b.id))
        #expect(fetched == b)
        #expect(fetched.notes == "details")
        #expect(fetched.estimatePomodoros == 3)
        #expect(fetched.tag == "work")
        #expect(try db.tasks.all().map(\.title) == ["A", "B"])
    }

    @Test func insertAndUpdateNormalizeScheduledDay() throws {
        var task = TaskItem(title: "T", createdAt: now, scheduledDay: Fixture.date(day: 20, 23, 59))
        try db.tasks.insert(task)
        #expect(try db.tasks.fetch(id: task.id)?.scheduledDay == Fixture.date(day: 20))

        task.title = "Renamed"
        task.scheduledDay = Fixture.date(day: 21, 0, 0, 1)
        try db.tasks.update(task)
        let fetched = try #require(try db.tasks.fetch(id: task.id))
        #expect(fetched.title == "Renamed")
        #expect(fetched.scheduledDay == Fixture.date(day: 21))
    }

    @Test func updateMissingTaskThrowsNotFound() throws {
        let ghost = TaskItem(title: "Ghost", createdAt: now)
        #expect(throws: StoreError.notFound(ghost.id)) { try db.tasks.update(ghost) }
        #expect(throws: StoreError.notFound(ghost.id)) { try db.tasks.setDone(id: ghost.id, true) }
        #expect(throws: StoreError.notFound(ghost.id)) { try db.tasks.schedule(id: ghost.id, on: nil) }
    }

    @Test func deleteRemovesTask() throws {
        let task = try db.tasks.create(title: "Bye", createdAt: now)
        #expect(try db.tasks.delete(id: task.id))
        #expect(try db.tasks.fetch(id: task.id) == nil)
        #expect(try db.tasks.delete(id: task.id) == false)
    }

    @Test func deletingTaskUnlinksBlocksAndSessionsButKeepsThem() throws {
        let task = try db.tasks.create(title: "Linked", createdAt: now)
        let block = TimeBlock(taskID: task.id, title: "Linked", start: now, duration: 1800)
        try db.blocks.insert(block)
        let session = FocusSession(
            taskID: task.id, blockID: block.id, start: now, end: now.addingTimeInterval(1500),
            plannedSeconds: 1500, completed: true
        )
        try db.sessions.insert(session)

        try db.tasks.delete(id: task.id)

        #expect(try db.blocks.fetch(id: block.id)?.taskID == nil)
        let kept = try #require(try db.sessions.fetch(id: session.id))
        #expect(kept.taskID == nil)
        #expect(kept.blockID == block.id)
    }

    @Test func setDoneStampsAndClearsDoneAt() throws {
        let task = try db.tasks.create(title: "Check", createdAt: now)
        let done = try db.tasks.setDone(id: task.id, true, at: now)
        #expect(done.isDone)
        #expect(done.doneAt == now)
        #expect(try db.tasks.fetch(id: task.id) == done)

        let reopened = try db.tasks.setDone(id: task.id, false, at: now)
        #expect(!reopened.isDone)
        #expect(reopened.doneAt == nil)
    }

    @Test func scheduleMovesBetweenDayAndInbox() throws {
        let task = try db.tasks.create(title: "Move", createdAt: now)
        let scheduled = try db.tasks.schedule(id: task.id, on: Fixture.date(day: 17, 22))
        #expect(scheduled.scheduledDay == Fixture.date(day: 17))
        #expect(try db.tasks.today(now: now).map(\.id) == [task.id])
        #expect(try db.tasks.inbox(now: now).isEmpty)

        try db.tasks.schedule(id: task.id, on: nil)
        #expect(try db.tasks.today(now: now).isEmpty)
        #expect(try db.tasks.inbox(now: now).map(\.id) == [task.id])
    }

    @Test func reorderAssignsSequentialIndices() throws {
        let a = try db.tasks.create(title: "A", createdAt: now)
        let b = try db.tasks.create(title: "B", createdAt: now)
        let c = try db.tasks.create(title: "C", createdAt: now)

        try db.tasks.reorder([c.id, a.id, b.id])

        #expect(try db.tasks.all().map(\.title) == ["C", "A", "B"])
        #expect(try db.tasks.all().map(\.sortIndex) == [0, 1, 2])
        #expect(try db.tasks.create(title: "D", createdAt: now).sortIndex == 3)
    }

    @Test func reorderIgnoresUnknownIDs() throws {
        let a = try db.tasks.create(title: "A", createdAt: now)
        let b = try db.tasks.create(title: "B", createdAt: now)
        try db.tasks.reorder([b.id, UUID(), a.id])
        #expect(try db.tasks.all().map(\.title) == ["B", "A"])
    }

    @Test func listOrderBreaksSortIndexTiesByCreation() throws {
        try db.tasks.insert(TaskItem(title: "Later", sortIndex: 0, createdAt: now.addingTimeInterval(60)))
        try db.tasks.insert(TaskItem(title: "Earlier", sortIndex: 0, createdAt: now))
        #expect(try db.tasks.all().map(\.title) == ["Earlier", "Later"])
    }

    @Test func todayIncludesTodayAndOpenOverdueTasks() throws {
        let today = try db.tasks.create(title: "Today", scheduledDay: Fixture.date(day: 17), createdAt: now)
        let todayDone = try db.tasks.create(title: "Today done", scheduledDay: Fixture.date(day: 17), createdAt: now)
        try db.tasks.setDone(id: todayDone.id, true, at: now)
        let overdue = try db.tasks.create(title: "Overdue", scheduledDay: Fixture.date(day: 15), createdAt: now)
        let overdueDone = try db.tasks.create(title: "Overdue done", scheduledDay: Fixture.date(day: 16), createdAt: now)
        try db.tasks.setDone(id: overdueDone.id, true, at: Fixture.date(day: 16, 12))
        try db.tasks.create(title: "Tomorrow", scheduledDay: Fixture.date(day: 18), createdAt: now)
        try db.tasks.create(title: "Inbox", createdAt: now)

        #expect(try db.tasks.today(now: now).map(\.id) == [today.id, todayDone.id, overdue.id])
    }

    @Test func todayBoundariesFollowTheCalendarDay() throws {
        try db.tasks.create(title: "Today", scheduledDay: Fixture.date(day: 17), createdAt: now)
        try db.tasks.create(title: "Tomorrow", scheduledDay: Fixture.date(day: 18), createdAt: now)

        #expect(try db.tasks.today(now: Fixture.date(day: 17)).map(\.title) == ["Today"])
        #expect(try db.tasks.today(now: Fixture.date(day: 17, 23, 59, 59)).map(\.title) == ["Today"])
        #expect(try db.tasks.today(now: Fixture.date(day: 18)).map(\.title) == ["Today", "Tomorrow"])
    }

    @Test func todayUsesTheStoreCalendarTimeZone() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let db = try Fixture.database(calendar: tokyo)
        // 23:30 UTC on the 16th is already the 17th in Tokyo.
        let lateUTC = Fixture.date(day: 16, 23, 30)
        let task = try db.tasks.create(title: "Tokyo", scheduledDay: lateUTC, createdAt: lateUTC)
        #expect(task.scheduledDay == Fixture.date(day: 17, calendar: tokyo))
        #expect(try db.tasks.today(now: Fixture.date(day: 17, 12, calendar: tokyo)).map(\.id) == [task.id])
    }

    @Test func inboxShowsOpenAndTodaysCheckOffsOnly() throws {
        let open = try db.tasks.create(title: "Open", createdAt: now)
        let doneToday = try db.tasks.create(title: "Done today", createdAt: now)
        try db.tasks.setDone(id: doneToday.id, true, at: Fixture.date(day: 17, 8))
        let doneYesterday = try db.tasks.create(title: "Done yesterday", createdAt: now)
        try db.tasks.setDone(id: doneYesterday.id, true, at: Fixture.date(day: 16, 23, 59))
        try db.tasks.create(title: "Scheduled", scheduledDay: Fixture.date(day: 17), createdAt: now)

        #expect(try db.tasks.inbox(now: now).map(\.id) == [open.id, doneToday.id])
    }

    @Test func observeTodayEmitsInitialValueAndChanges() async throws {
        var iterator = db.tasks.observeToday(now: now).makeAsyncIterator()
        let value1 = await iterator.next()
        #expect(value1 == [])

        let task = try db.tasks.create(title: "Live", scheduledDay: now, createdAt: now)
        let value2 = await iterator.next()
        #expect(value2 == [task])
    }

    @Test func observeInboxEmitsChanges() async throws {
        var iterator = db.tasks.observeInbox(now: now).makeAsyncIterator()
        let value3 = await iterator.next()
        #expect(value3 == [])

        let task = try db.tasks.create(title: "Live", createdAt: now)
        let value4 = await iterator.next()
        #expect(value4 == [task])

        try db.tasks.schedule(id: task.id, on: now)
        let value5 = await iterator.next()
        #expect(value5 == [])
    }

    @Test func observeAllEmitsReorders() async throws {
        let a = try db.tasks.create(title: "A", createdAt: now)
        let b = try db.tasks.create(title: "B", createdAt: now)
        var iterator = db.tasks.observeAll().makeAsyncIterator()
        let value6 = await iterator.next()
        #expect(value6?.map(\.id) == [a.id, b.id])

        try db.tasks.reorder([b.id, a.id])
        let value7 = await iterator.next()
        #expect(value7?.map(\.id) == [b.id, a.id])
    }
}
