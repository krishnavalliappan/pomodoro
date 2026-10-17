import Foundation
import Testing
@testable import PomodoroCore

@Suite(.timeLimit(.minutes(1)))
struct StatsRepositoryTests {
    let db: AppDatabase

    init() throws {
        db = try Fixture.database()
    }

    @discardableResult
    private func session(day: Int, _ hour: Int, minutes: Double = 25, completed: Bool = true, taskID: UUID? = nil) throws -> FocusSession {
        let start = Fixture.date(day: day, hour)
        let session = FocusSession(
            taskID: taskID, start: start, end: start.addingTimeInterval(minutes * 60),
            plannedSeconds: 1500, activeSeconds: minutes * 60, completed: completed
        )
        try db.sessions.insert(session)
        return session
    }

    @Test func todaySummaryReadsTodayAndTheStreak() throws {
        try session(day: 15, 9)
        try session(day: 16, 9)
        try session(day: 17, 9)
        try session(day: 17, 10, minutes: 75)
        try session(day: 17, 11, minutes: 5, completed: false)
        let summary = try db.stats.todaySummary(now: Fixture.date(day: 17, 15))
        #expect(summary == TodaySummary(
            day: Fixture.day(17), focusedSeconds: 105 * 60, completedPomodoros: 2, streak: Streak(current: 3, best: 3)))
        let empty = try db.stats.todaySummary(now: Fixture.date(day: 18, 8))
        #expect(empty == TodaySummary(day: Fixture.day(18), streak: Streak(current: 3, best: 3)))
    }

    @Test func recentDaysEndTodayAndIncludeEmptyDays() throws {
        try session(day: 10, 9)
        try session(day: 11, 9)
        try session(day: 14, 9, minutes: 50)
        try session(day: 17, 9)
        try session(day: 17, 10, minutes: 10, completed: false)
        try session(day: 18, 9)
        let days = try db.stats.recentDays(7, now: Fixture.date(day: 17, 15))
        #expect(days.map(\.day) == (11...17).map { Fixture.day($0) })
        #expect(days.map(\.focusedSeconds) == [25, 0, 0, 50, 0, 0, 35].map { TimeInterval($0 * 60) })
        #expect(days.map(\.completedPomodoros) == [1, 0, 0, 1, 0, 0, 1])
        #expect(try db.stats.recentDays(0, now: Fixture.date(day: 17, 15)).isEmpty)
    }

    @Test func weekReportJoinsTasksAndAllTimeActuals() throws {
        let spec = try db.tasks.create(title: "Write spec", estimatePomodoros: 3, createdAt: Fixture.date(day: 1))
        try session(day: 2, 9, taskID: spec.id)
        try session(day: 13, 9, minutes: 50, taskID: spec.id)
        try session(day: 14, 9)
        try session(day: 7, 9, minutes: 30)
        let stats = db.stats.stats(firstWeekday: 2)
        let week = stats.week(containing: Fixture.day(17))
        let report = try db.stats.weekReport(week, stats: stats, now: Fixture.date(day: 17, 15))
        #expect(report.week.start == Fixture.day(12))
        #expect(report.today == Fixture.day(17))
        #expect(report.totalSeconds == 75 * 60)
        #expect(report.previousWeekSeconds == 30 * 60)
        #expect(report.topTasks.count == 1)
        let top = try #require(report.topTasks.first)
        #expect(top.title == "Write spec")
        #expect(top.estimatePomodoros == 3)
        #expect(top.week.completedPomodoros == 1)
        #expect(top.allTime.completedPomodoros == 2)
        #expect(top.allTime.focusedSeconds == 75 * 60)
    }

    @Test func observeWeekReportEmitsAfterInsert() async throws {
        let stats = db.stats.stats(firstWeekday: 2)
        let week = stats.week(containing: Fixture.day(17))
        var iterator = db.stats.observeWeekReport(week, stats: stats, now: Fixture.date(day: 17, 15)).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.isEmpty == true)

        try session(day: 16, 9)
        let second = await iterator.next()
        #expect(second?.totalSeconds == TimeInterval(25 * 60))
        #expect(second?.streak == Streak(current: 1, best: 1))
    }
}
