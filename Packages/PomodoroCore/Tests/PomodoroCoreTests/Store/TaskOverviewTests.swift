import Foundation
import Testing
@testable import PomodoroCore

@Suite(.timeLimit(.minutes(1)))
struct TaskOverviewTests {
    let db: AppDatabase
    let now = Fixture.date(day: 17, 14, 30)

    init() throws {
        db = try Fixture.database()
    }

    private func session(task: UUID?, completed: Bool = true, at hour: Int = 9) -> FocusSession {
        let start = Fixture.date(day: 17, hour)
        return FocusSession(
            taskID: task, start: start, end: start + 1500, plannedSeconds: 1500,
            activeSeconds: completed ? 1500 : 600, completed: completed
        )
    }

    @Test func groupsTodayInboxAndUpcoming() throws {
        let today = try db.tasks.create(title: "Today", scheduledDay: Fixture.day(17), createdAt: now)
        let overdue = try db.tasks.create(title: "Overdue", scheduledDay: Fixture.day(15), createdAt: now)
        let inbox = try db.tasks.create(title: "Inbox", createdAt: now)
        let later = try db.tasks.create(title: "Later", scheduledDay: Fixture.day(20), createdAt: now)
        let tomorrow = try db.tasks.create(title: "Tomorrow", scheduledDay: Fixture.day(18), createdAt: now)
        let doneTomorrow = try db.tasks.create(title: "Done early", scheduledDay: Fixture.day(18), createdAt: now)
        try db.tasks.setDone(id: doneTomorrow.id, true, at: now)

        let overview = try db.tasks.overview(now: now)
        #expect(overview.day == Fixture.day(17))
        #expect(overview.today.map(\.id) == [today.id, overdue.id])
        #expect(overview.inbox.map(\.id) == [inbox.id])
        #expect(overview.upcoming.map(\.id) == [tomorrow.id, later.id], "soonest day first, done ones hidden")
    }

    @Test func batchesActualsForEveryListedTask() throws {
        let a = try db.tasks.create(title: "A", scheduledDay: Fixture.day(17), createdAt: now)
        let b = try db.tasks.create(title: "B", createdAt: now)
        let c = try db.tasks.create(title: "C", scheduledDay: Fixture.day(19), createdAt: now)
        try db.sessions.insert(session(task: a.id, at: 8))
        try db.sessions.insert(session(task: a.id, at: 9))
        try db.sessions.insert(session(task: b.id, completed: false, at: 10))
        try db.sessions.insert(session(task: nil, at: 11))

        let overview = try db.tasks.overview(now: now)
        #expect(overview.actuals(for: a.id).completedPomodoros == 2)
        #expect(overview.actuals(for: b.id) == TaskActuals(completedPomodoros: 0, sessionCount: 1, focusedSeconds: 600))
        #expect(overview.actuals(for: c.id) == .zero)
        #expect(overview.actuals[c.id] == nil)
    }

    @Test func emptyStoreHasAnEmptyOverview() throws {
        #expect(try db.tasks.overview(now: now) == TaskOverview(day: Fixture.day(17)))
    }

    @Test func observeOverviewUpdatesActualsLive() async throws {
        let task = try db.tasks.create(title: "Live", scheduledDay: Fixture.day(17), createdAt: now)
        var iterator = db.tasks.observeOverview(now: now).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.today.map(\.id) == [task.id])
        #expect(first?.actuals(for: task.id) == .zero)

        try db.sessions.insert(session(task: task.id))
        let second = await iterator.next()
        #expect(second?.actuals(for: task.id).completedPomodoros == 1)
    }

    @Test func observeOverviewKeepsTheDayItWasGiven() async throws {
        var iterator = db.tasks.observeOverview(now: now).makeAsyncIterator()
        _ = await iterator.next()
        // A task for tomorrow stays upcoming however late the stream runs: the subscriber re-subscribes at midnight.
        let task = try db.tasks.create(title: "Tomorrow", scheduledDay: Fixture.day(18), createdAt: now)
        let next = await iterator.next()
        #expect(next?.day == Fixture.day(17))
        #expect(next?.upcoming.map(\.id) == [task.id])
        #expect(next?.today == [])
    }
}

@Suite
struct QuickAddCreateTests {
    let db: AppDatabase
    let now = Fixture.date(day: 17, 9)
    let parser = QuickAddParser(calendar: Fixture.utc)

    init() throws {
        db = try Fixture.database()
    }

    @Test func createsTaskWithMetadataOnTheDefaultDay() throws {
        let entry = parser.parse("Write spec ~3 #work", now: now)
        let created = try #require(try db.tasks.create(entry, defaultDay: Fixture.day(17), createdAt: now))
        #expect(created.block == nil)
        #expect(created.task.title == "Write spec")
        #expect(created.task.estimatePomodoros == 3)
        #expect(created.task.tag == "work")
        #expect(created.task.scheduledDay == Fixture.day(17))
        #expect(created.task.createdAt == now)
        #expect(try db.tasks.fetch(id: created.task.id) == created.task)
        #expect(try db.blocks.blocks(onDayContaining: now).isEmpty)
    }

    @Test func aStartTimeAlsoCreatesALinkedBlock() throws {
        let entry = parser.parse("Review PR ~2 @14:00 45m tomorrow", now: now)
        let created = try #require(try db.tasks.create(entry, defaultDay: Fixture.day(17), createdAt: now))
        let block = try #require(created.block)
        #expect(created.task.scheduledDay == Fixture.day(18), "the parsed day wins over the default")
        #expect(block.taskID == created.task.id)
        #expect(block.title == "Review PR")
        #expect(block.start == Fixture.date(day: 18, 14))
        #expect(block.duration == 45 * 60)
        #expect(try db.blocks.block(at: Fixture.date(day: 18, 14, 30)) == block)
    }

    @Test func aNilDefaultDayLandsInTheInbox() throws {
        let created = try #require(try db.tasks.create(parser.parse("Someday", now: now), defaultDay: nil, createdAt: now))
        #expect(created.task.scheduledDay == nil)
        #expect(try db.tasks.inbox(now: now).map(\.id) == [created.task.id])
    }

    @Test func appendsAfterExistingTasks() throws {
        try db.tasks.create(title: "First", createdAt: now)
        let created = try #require(try db.tasks.create(parser.parse("Second", now: now), defaultDay: nil, createdAt: now))
        #expect(created.task.sortIndex == 1)
    }

    @Test func blankTitlesCreateNothing() throws {
        #expect(try db.tasks.create(parser.parse("   ", now: now), defaultDay: nil, createdAt: now) == nil)
        #expect(try db.tasks.create(parser.parse("~3 #work", now: now), defaultDay: nil, createdAt: now) == nil)
        #expect(try db.tasks.create(QuickAddResult(title: " \n"), defaultDay: nil, createdAt: now) == nil)
        #expect(try db.tasks.all().isEmpty)
    }

    @Test func anInvalidBlockDurationWritesNothing() throws {
        let entry = QuickAddResult(title: "Bad", blockStart: now, blockDuration: 0)
        #expect(throws: StoreError.invalidDuration(0)) {
            try db.tasks.create(entry, defaultDay: nil, createdAt: now)
        }
        #expect(try db.tasks.all().isEmpty)
    }
}
