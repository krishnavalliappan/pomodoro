import Foundation
import Testing
@testable import PomodoroCore

// Observation tests await stream values; fail fast instead of hanging CI if one never arrives.
@Suite(.timeLimit(.minutes(1)))
struct FocusSessionRepositoryTests {
    let db: AppDatabase

    init() throws {
        db = try Fixture.database()
    }

    @discardableResult
    private func session(
        day: Int = 17, _ hour: Int, _ minute: Int = 0, minutes: Double = 25, overtime: Double = 0,
        completed: Bool = true, taskID: UUID? = nil, blockID: UUID? = nil
    ) throws -> FocusSession {
        let start = Fixture.date(day: day, hour, minute)
        let session = FocusSession(
            taskID: taskID, blockID: blockID, start: start,
            end: start.addingTimeInterval((minutes + overtime) * 60),
            plannedSeconds: minutes * 60, overtimeSeconds: overtime * 60, completed: completed
        )
        try db.sessions.insert(session)
        return session
    }

    @Test func constructsFromPlainFields() {
        let start = Fixture.date(day: 17, 9)
        let session = FocusSession(
            start: start, end: start.addingTimeInterval(1700), plannedSeconds: 1500, overtimeSeconds: 200,
            completed: true
        )
        #expect(session.taskID == nil)
        #expect(session.blockID == nil)
        #expect(session.duration == 1700)
    }

    @Test func insertFetchDeleteRoundTrip() throws {
        let task = try db.tasks.create(title: "T", createdAt: Fixture.date(day: 17))
        let block = TimeBlock(taskID: task.id, title: "T", start: Fixture.date(day: 17, 9), duration: 3600)
        try db.blocks.insert(block)
        let s = try session(9, overtime: 3, taskID: task.id, blockID: block.id)

        #expect(try db.sessions.fetch(id: s.id) == s)
        #expect(try db.sessions.delete(id: s.id))
        #expect(try db.sessions.fetch(id: s.id) == nil)
    }

    @Test func deletingBlockKeepsSessionUnlinked() throws {
        let block = TimeBlock(title: "B", start: Fixture.date(day: 17, 9), duration: 3600)
        try db.blocks.insert(block)
        let s = try session(9, blockID: block.id)
        try db.blocks.delete(id: block.id)
        #expect(try db.sessions.fetch(id: s.id)?.blockID == nil)
    }

    @Test func sessionsInRangeFilterByStartAndSort() throws {
        let late = try session(15)
        let early = try session(9)
        try session(day: 16, 23, 50)  // started yesterday, ends today
        try session(day: 18, 0)

        let range = Fixture.date(day: 17)..<Fixture.date(day: 18)
        #expect(try db.sessions.sessions(in: range).map(\.id) == [early.id, late.id])
    }

    @Test func sessionsForTask() throws {
        let task = try db.tasks.create(title: "T", createdAt: Fixture.date(day: 17))
        let second = try session(11, taskID: task.id)
        let first = try session(9, taskID: task.id)
        try session(10)
        #expect(try db.sessions.sessions(forTask: task.id).map(\.id) == [first.id, second.id])
    }

    @Test func actualsCountCompletedAndSumWallClockIncludingOvertime() throws {
        let task = try db.tasks.create(title: "T", createdAt: Fixture.date(day: 17))
        try session(9, overtime: 5, taskID: task.id)                  // 30 min, completed
        try session(10, taskID: task.id)                              // 25 min, completed
        try session(11, completed: false, taskID: task.id)                // 25 min, not completed
        let stoppedEarly = FocusSession(
            taskID: task.id, start: Fixture.date(day: 17, 12), end: Fixture.date(day: 17, 12, 10),
            plannedSeconds: 1500, completed: false
        )
        try db.sessions.insert(stoppedEarly)                          // 10 min, not completed
        try session(13)                                               // no task

        let actuals = try db.sessions.actuals(forTask: task.id)
        #expect(actuals.completedPomodoros == 2)
        #expect(actuals.sessionCount == 4)
        #expect(actuals.focusedSeconds == (30 + 25 + 25 + 10) * 60)
    }

    @Test func actualsForTaskWithoutSessionsIsZero() throws {
        let task = try db.tasks.create(title: "T", createdAt: Fixture.date(day: 17))
        #expect(try db.sessions.actuals(forTask: task.id) == .zero)
        #expect(try db.sessions.actuals(forTask: UUID()) == .zero)
    }

    @Test func batchedActualsGroupByTask() throws {
        let a = try db.tasks.create(title: "A", createdAt: Fixture.date(day: 17))
        let b = try db.tasks.create(title: "B", createdAt: Fixture.date(day: 17))
        let idle = try db.tasks.create(title: "Idle", createdAt: Fixture.date(day: 17))
        try session(9, taskID: a.id)
        try session(10, taskID: a.id)
        try session(11, minutes: 50, overtime: 2, taskID: b.id)

        let actuals = try db.sessions.actuals(forTasks: [a.id, b.id, idle.id])
        #expect(actuals == [
            a.id: TaskActuals(completedPomodoros: 2, sessionCount: 2, focusedSeconds: 3000),
            b.id: TaskActuals(completedPomodoros: 1, sessionCount: 1, focusedSeconds: 3120),
        ])
        #expect(try db.sessions.actuals(forTasks: [UUID]()) == [:])
    }

    @Test func dailyTotalsCoverEveryDayInRange() throws {
        try session(day: 15, 9)
        try session(day: 15, 10, overtime: 5)
        try session(day: 15, 11, minutes: 10, completed: false)
        try session(day: 17, 23, 50)   // counts toward the 17th even though it ends on the 18th
        try session(day: 18, 9)        // outside range

        let totals = try db.sessions.dailyTotals(in: Fixture.date(day: 15)..<Fixture.date(day: 18))
        #expect(totals == [
            DayTotal(day: Fixture.date(day: 15), completedPomodoros: 2, sessionCount: 3, focusedSeconds: (25 + 30 + 10) * 60),
            DayTotal(day: Fixture.date(day: 16)),
            DayTotal(day: Fixture.date(day: 17), completedPomodoros: 1, sessionCount: 1, focusedSeconds: 25 * 60),
        ])
    }

    @Test func dailyTotalsOfEmptyRangeIsEmpty() throws {
        let day = Fixture.date(day: 17)
        #expect(try db.sessions.dailyTotals(in: day..<day).isEmpty)
    }

    @Test func totalOnDay() throws {
        try session(9)
        try session(14, overtime: 1)
        try session(day: 16, 9)

        #expect(try db.sessions.total(onDayContaining: Fixture.date(day: 17, 18)) == DayTotal(
            day: Fixture.date(day: 17), completedPomodoros: 2, sessionCount: 2, focusedSeconds: 51 * 60
        ))
        #expect(try db.sessions.total(onDayContaining: Fixture.date(day: 20)) == DayTotal(day: Fixture.date(day: 20)))
    }

    @Test func dailyTotalsFollowStoreTimeZoneAcrossDST() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let db = try Fixture.database(calendar: berlin)
        // Berlin leaves DST on Oct 25, 2026, so that day is 25 hours long.
        for (day, hour) in [(25, 0), (25, 23), (26, 0)] {
            let start = Fixture.date(day: day, hour, 30, calendar: berlin)
            try db.sessions.insert(FocusSession(
                start: start, end: start.addingTimeInterval(1500), plannedSeconds: 1500, completed: true
            ))
        }

        let range = Fixture.date(day: 25, calendar: berlin)..<Fixture.date(day: 27, calendar: berlin)
        let totals = try db.sessions.dailyTotals(in: range)
        #expect(totals.map(\.day) == [Fixture.date(day: 25, calendar: berlin), Fixture.date(day: 26, calendar: berlin)])
        #expect(totals.map(\.sessionCount) == [2, 1])
        #expect(totals[1].day.timeIntervalSince(totals[0].day) == 25 * 3600)
    }

    @Test func observeActualsEmitsAfterInsert() async throws {
        let task = try db.tasks.create(title: "T", createdAt: Fixture.date(day: 17))
        var iterator = db.sessions.observeActuals(forTasks: [task.id]).makeAsyncIterator()
        let value1 = await iterator.next()
        #expect(value1 == [:])

        try session(9, taskID: task.id)
        let value2 = await iterator.next()
        #expect(value2 == [task.id: TaskActuals(completedPomodoros: 1, sessionCount: 1, focusedSeconds: 1500)])
    }

    @Test func observeDailyTotalsEmitsAfterInsert() async throws {
        let range = Fixture.date(day: 17)..<Fixture.date(day: 18)
        var iterator = db.sessions.observeDailyTotals(in: range).makeAsyncIterator()
        let value3 = await iterator.next()
        #expect(value3 == [DayTotal(day: Fixture.date(day: 17))])

        try session(9)
        let value4 = await iterator.next()
        #expect(value4 == [
            DayTotal(day: Fixture.date(day: 17), completedPomodoros: 1, sessionCount: 1, focusedSeconds: 1500),
        ])
    }
}
