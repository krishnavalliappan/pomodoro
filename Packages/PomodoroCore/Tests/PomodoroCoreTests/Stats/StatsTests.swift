import Foundation
import Testing
@testable import PomodoroCore

struct StatsTests {
    static let newYork = Fixture.calendar("America/New_York")

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CivilDay {
        CivilDay(year: year, month: month, day: day)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar = Fixture.utc) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func session(
        _ start: Date, minutes: Double = 25, paused: Double = 0, completed: Bool = true, taskID: UUID? = nil
    ) -> FocusSession {
        FocusSession(
            taskID: taskID, start: start, end: start.addingTimeInterval((minutes + paused) * 60),
            plannedSeconds: 1500, activeSeconds: minutes * 60, pausedSeconds: paused * 60, completed: completed
        )
    }

    // MARK: - CivilDay arithmetic

    @Test func civilDayWeekdayAndArithmetic() {
        #expect(day(2026, 10, 17).weekday == 7)  // Saturday
        #expect(day(2026, 10, 18).weekday == 1)
        #expect(day(2026, 10, 31).adding(days: 1) == day(2026, 11, 1))
        #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(day(2028, 3, 1).adding(days: -1) == day(2028, 2, 29))
        #expect(day(2026, 3, 8).adding(days: 1) == day(2026, 3, 9))
        #expect(day(2026, 12, 25).days(to: day(2027, 1, 4)) == 10)
        #expect(day(2027, 1, 4).days(to: day(2026, 12, 25)) == -10)
    }

    @Test func daysEndingOnCrossMonthsOldestFirst() {
        let stats = Stats(calendar: Fixture.utc)
        #expect(stats.days(endingOn: day(2026, 11, 2), count: 4) == [day(2026, 10, 30), day(2026, 10, 31), day(2026, 11, 1), day(2026, 11, 2)])
        #expect(stats.days(endingOn: day(2026, 11, 2), count: 1) == [day(2026, 11, 2)])
        #expect(stats.days(endingOn: day(2026, 11, 2), count: 0).isEmpty)
    }

    // MARK: - Weeks

    @Test func firstWeekdayDefaultsToTheCalendars() {
        var monday = Fixture.utc
        monday.firstWeekday = 2
        #expect(Stats(calendar: monday).firstWeekday == 2)
        #expect(Stats(calendar: monday, firstWeekday: nil).firstWeekday == 2)
        #expect(Stats(calendar: monday, firstWeekday: 0).firstWeekday == 2)
        #expect(Stats(calendar: monday, firstWeekday: 8).firstWeekday == 2)
        #expect(Stats(calendar: monday, firstWeekday: 1).firstWeekday == 1)
    }

    @Test(arguments: [
        (1, CivilDay(year: 2026, month: 10, day: 11)),
        (2, CivilDay(year: 2026, month: 10, day: 12)),
        (7, CivilDay(year: 2026, month: 10, day: 17)),
        (6, CivilDay(year: 2026, month: 10, day: 16)),
    ])
    func weekStartFollowsFirstWeekday(firstWeekday: Int, start: CivilDay) {
        let week = Stats(calendar: Fixture.utc, firstWeekday: firstWeekday).week(containing: day(2026, 10, 17))
        #expect(week.start == start)
        #expect(week.days.count == 7)
        #expect(week.contains(day(2026, 10, 17)))
        #expect(week.days.first?.weekday == firstWeekday)
    }

    @Test func weekSpansMonthAndYearBoundaries() {
        let stats = Stats(calendar: Fixture.utc, firstWeekday: 2)
        let week = stats.week(containing: day(2027, 1, 1))
        #expect(week.start == day(2026, 12, 28))
        #expect(week.last == day(2027, 1, 3))
        #expect(week.days == [
            day(2026, 12, 28), day(2026, 12, 29), day(2026, 12, 30), day(2026, 12, 31),
            day(2027, 1, 1), day(2027, 1, 2), day(2027, 1, 3),
        ])
        #expect(week.previous.start == day(2026, 12, 21))
        #expect(week.next.start == day(2027, 1, 4))
        #expect(stats.week(containing: day(2026, 10, 31)).days.contains(day(2026, 11, 1)))
    }

    @Test func weekContainingADateUsesTheCalendarsZone() {
        // 02:00 UTC on Sunday 18 October is still Saturday evening in New York.
        let instant = date(2026, 10, 18, 2)
        #expect(Stats(calendar: Fixture.utc, firstWeekday: 1).week(containing: instant).start == day(2026, 10, 18))
        #expect(Stats(calendar: Self.newYork, firstWeekday: 1).week(containing: instant).start == day(2026, 10, 11))
    }

    @Test func weekRangeStretchesAndShrinksAcrossDST() {
        let stats = Stats(calendar: Self.newYork, firstWeekday: 2)
        let fallBack = stats.range(of: stats.week(containing: day(2026, 11, 1)))
        #expect(fallBack.upperBound.timeIntervalSince(fallBack.lowerBound) == 7 * 86_400 + 3600)
        let springForward = stats.range(of: stats.week(containing: day(2026, 3, 8)))
        #expect(springForward.upperBound.timeIntervalSince(springForward.lowerBound) == 7 * 86_400 - 3600)
        #expect(stats.range(of: day(2026, 11, 1)).lowerBound == date(2026, 11, 1, 0, in: Self.newYork))
    }

    // MARK: - Daily focus

    @Test func dailyFocusSumsActiveTimeOnTheStartDay() {
        let stats = Stats(calendar: Fixture.utc, firstWeekday: 2)
        let week = stats.week(containing: day(2026, 10, 14))
        let sessions = [
            session(date(2026, 10, 12, 9)),
            session(date(2026, 10, 12, 10), minutes: 40, paused: 10),
            // Runs past midnight; it all counts toward the day it started.
            session(date(2026, 10, 14, 23, 50), minutes: 30),
            session(date(2026, 10, 15, 9), minutes: 10, completed: false),
            // Outside the week.
            session(date(2026, 10, 11, 23, 59)),
            session(date(2026, 10, 19, 0, 0)),
        ]
        let days = stats.dailyFocus(sessions, in: week)
        #expect(days.map(\.day) == week.days)
        let minutes: [TimeInterval] = [65, 0, 30, 10, 0, 0, 0]
        #expect(days.map(\.focusedSeconds) == minutes.map { $0 * 60 })
        #expect(days.map(\.completedPomodoros) == [2, 0, 1, 0, 0, 0, 0])
        #expect(days.map(\.sessionCount) == [2, 0, 1, 1, 0, 0, 0])
    }

    @Test func dailyFocusAcrossDSTUsesLocalDays() {
        let stats = Stats(calendar: Self.newYork)
        // 1 November 2026 is 25 hours long in New York; both of these belong to it.
        let early = session(date(2026, 11, 1, 0, 30, in: Self.newYork))
        let late = session(date(2026, 11, 1, 23, 30, in: Self.newYork))
        let next = session(date(2026, 11, 2, 0, 10, in: Self.newYork))
        let days = stats.dailyFocus([early, late, next], on: [day(2026, 11, 1), day(2026, 11, 2)])
        #expect(days.map(\.completedPomodoros) == [2, 1])
        // In UTC the late one is already 2 November.
        let utc = Stats(calendar: Fixture.utc).dailyFocus([early, late, next], on: [day(2026, 11, 1), day(2026, 11, 2)])
        #expect(utc.map(\.completedPomodoros) == [1, 2])
    }

    @Test func weeklyBucketsDependOnFirstWeekday() {
        // Sunday 18 October.
        let sunday = [session(date(2026, 10, 18, 9), minutes: 50)]
        let sundayFirst = Stats(calendar: Fixture.utc, firstWeekday: 1)
        let mondayFirst = Stats(calendar: Fixture.utc, firstWeekday: 2)
        let ofSundayWeek = sundayFirst.dailyFocus(sunday, in: sundayFirst.week(containing: day(2026, 10, 17)))
        let ofMondayWeek = mondayFirst.dailyFocus(sunday, in: mondayFirst.week(containing: day(2026, 10, 17)))
        #expect(ofSundayWeek.reduce(0) { $0 + $1.focusedSeconds } == 0)
        #expect(ofMondayWeek.reduce(0) { $0 + $1.focusedSeconds } == 50 * 60)
        #expect(ofMondayWeek.last?.focusedSeconds == TimeInterval(50 * 60))
    }

    // MARK: - Task actuals

    @Test func taskActualsCountCompletedPomodorosAndMinutes() {
        let a = UUID()
        let b = UUID()
        let actuals = Stats(calendar: Fixture.utc).taskActuals([
            session(date(2026, 10, 17, 9), taskID: a),
            session(date(2026, 10, 17, 10), minutes: 35, taskID: a),
            session(date(2026, 10, 17, 11), minutes: 5, completed: false, taskID: a),
            session(date(2026, 10, 17, 12), taskID: b),
            session(date(2026, 10, 17, 13)),
        ])
        #expect(actuals == [
            a: TaskActuals(completedPomodoros: 2, sessionCount: 3, focusedSeconds: 65 * 60),
            b: TaskActuals(completedPomodoros: 1, sessionCount: 1, focusedSeconds: 25 * 60),
        ])
    }

    // MARK: - Streaks

    private func streak(_ days: [CivilDay], today: CivilDay, calendar: Calendar = Fixture.utc) -> Streak {
        Stats(calendar: calendar).streak(focusDays: Set(days), today: today)
    }

    @Test func noFocusNoStreak() {
        #expect(streak([], today: day(2026, 10, 17)) == .zero)
    }

    @Test func todayCountsOnceItHasAFocus() {
        let days = [day(2026, 10, 15), day(2026, 10, 16), day(2026, 10, 17)]
        #expect(streak(days, today: day(2026, 10, 17)) == Streak(current: 3, best: 3))
    }

    @Test func todayWithoutAFocusYetKeepsTheStreak() {
        let days = [day(2026, 10, 15), day(2026, 10, 16)]
        #expect(streak(days, today: day(2026, 10, 17)) == Streak(current: 2, best: 2))
    }

    @Test func streakBreaksOnlyOnceADayEndsWithoutFocus() {
        let days = [day(2026, 10, 14), day(2026, 10, 15)]
        // The 16th ended empty.
        #expect(streak(days, today: day(2026, 10, 17)) == Streak(current: 0, best: 2))
        #expect(streak(days + [day(2026, 10, 17)], today: day(2026, 10, 17)) == Streak(current: 1, best: 2))
    }

    @Test func bestStreakComesFromHistory() {
        let old = (1...9).map { day(2026, 9, $0) }
        let recent = [day(2026, 10, 16), day(2026, 10, 17)]
        #expect(streak(old + recent, today: day(2026, 10, 17)) == Streak(current: 2, best: 9))
    }

    @Test func daysAfterTodayAreIgnored() {
        let days = [day(2026, 10, 17), day(2026, 10, 18), day(2026, 10, 19), day(2026, 10, 20)]
        #expect(streak(days, today: day(2026, 10, 17)) == Streak(current: 1, best: 1))
    }

    @Test func streakRunsAcrossMonthAndYearBoundaries() {
        let month = [day(2026, 9, 29), day(2026, 9, 30), day(2026, 10, 1), day(2026, 10, 2)]
        #expect(streak(month, today: day(2026, 10, 2)) == Streak(current: 4, best: 4))
        let year = [day(2026, 12, 30), day(2026, 12, 31), day(2027, 1, 1)]
        #expect(streak(year, today: day(2027, 1, 2)) == Streak(current: 3, best: 3))
        let leap = [day(2028, 2, 28), day(2028, 2, 29), day(2028, 3, 1)]
        #expect(streak(leap, today: day(2028, 3, 1)) == Streak(current: 3, best: 3))
    }

    @Test func streakRunsAcrossDSTChanges() {
        let stats = Stats(calendar: Self.newYork)
        // Late evenings either side of the 25-hour 1 November, and of the 23-hour 8 March.
        let fallBack = [
            date(2026, 10, 31, 23, 30, in: Self.newYork),
            date(2026, 11, 1, 23, 30, in: Self.newYork),
            date(2026, 11, 2, 0, 15, in: Self.newYork),
        ].map { session($0) }
        let fallDays = stats.focusDays(fallBack)
        #expect(fallDays == [day(2026, 10, 31), day(2026, 11, 1), day(2026, 11, 2)])
        #expect(stats.streak(focusDays: fallDays, today: day(2026, 11, 2)) == Streak(current: 3, best: 3))

        let springForward = [
            date(2026, 3, 7, 23, 45, in: Self.newYork),
            date(2026, 3, 8, 3, 0, in: Self.newYork),
            date(2026, 3, 9, 0, 5, in: Self.newYork),
        ].map { session($0) }
        let springDays = stats.focusDays(springForward)
        #expect(springDays == [day(2026, 3, 7), day(2026, 3, 8), day(2026, 3, 9)])
        // The 10th hasn't ended, so the streak still stands.
        #expect(stats.streak(focusDays: springDays, today: day(2026, 3, 10)) == Streak(current: 3, best: 3))
    }

    @Test func onlyCompletedFocusesMakeAStreakDay() {
        let stats = Stats(calendar: Fixture.utc)
        let days = stats.focusDays([
            session(date(2026, 10, 15, 9)),
            session(date(2026, 10, 16, 9), minutes: 20, completed: false),
            session(date(2026, 10, 17, 9)),
        ])
        #expect(days == [day(2026, 10, 15), day(2026, 10, 17)])
        #expect(stats.streak(focusDays: days, today: day(2026, 10, 17)) == Streak(current: 1, best: 1))
    }

    @Test func focusDaysFromUnsortedStarts() {
        let stats = Stats(calendar: Fixture.utc)
        let starts = [date(2026, 10, 17, 9), date(2026, 10, 15, 23, 59), date(2026, 10, 17, 0, 0), date(2026, 10, 16, 0, 0), date(2026, 10, 15, 1)]
        #expect(stats.focusDays(completedStarts: starts) == [day(2026, 10, 15), day(2026, 10, 16), day(2026, 10, 17)])
    }

    // MARK: - Reports

    @Test func todaySummaryTotalsTodayAndCarriesTheStreak() {
        let stats = Stats(calendar: Fixture.utc)
        let sessions = [
            session(date(2026, 10, 17, 9)),
            session(date(2026, 10, 17, 10), minutes: 75),
            session(date(2026, 10, 17, 12), minutes: 5, completed: false),
            session(date(2026, 10, 16, 9)),
        ]
        let summary = stats.todaySummary(today: day(2026, 10, 17), sessions: sessions, focusDays: stats.focusDays(sessions))
        #expect(summary == TodaySummary(
            day: day(2026, 10, 17), focusedSeconds: 105 * 60, completedPomodoros: 2, streak: Streak(current: 2, best: 2)))
    }

    @Test func weekReportRanksTasksAndComparesWithLastWeek() {
        let stats = Stats(calendar: Fixture.utc, firstWeekday: 2)
        let week = stats.week(containing: day(2026, 10, 17))
        let created = date(2026, 10, 1, 9)
        let spec = TaskItem(title: "Write spec", estimatePomodoros: 3, createdAt: created)
        let review = TaskItem(title: "Review PR", estimatePomodoros: 2, createdAt: created)
        let email = TaskItem(title: "Email", createdAt: created)
        let deleted = UUID()
        let sessions = [
            session(date(2026, 10, 12, 9), minutes: 50, taskID: spec.id),
            session(date(2026, 10, 13, 9), taskID: review.id),
            session(date(2026, 10, 13, 10), taskID: review.id),
            session(date(2026, 10, 14, 9), minutes: 10, taskID: email.id),
            session(date(2026, 10, 15, 9), minutes: 90, taskID: deleted),
            session(date(2026, 10, 16, 9)),
            // Last week.
            session(date(2026, 10, 5, 9), minutes: 30, taskID: spec.id),
            session(date(2026, 10, 11, 23), minutes: 20),
        ]
        let report = stats.weekReport(
            week, sessions: sessions,
            tasks: [spec.id: spec, review.id: review, email.id: email],
            actuals: [spec.id: TaskActuals(completedPomodoros: 4, sessionCount: 4, focusedSeconds: 120 * 60)],
            focusDays: stats.focusDays(sessions), today: day(2026, 10, 17), topTaskLimit: 2
        )
        #expect(report.week == week)
        let minutes: [TimeInterval] = [50, 50, 10, 90, 25, 0, 0]
        #expect(report.days.map(\.focusedSeconds) == minutes.map { $0 * 60 })
        #expect(report.totalSeconds == 225 * 60)
        #expect(report.completedPomodoros == 6)
        #expect(report.previousWeekSeconds == 50 * 60)
        #expect(report.topTasks.map(\.title) == ["Review PR", "Write spec"])
        #expect(report.topTasks[0].week == TaskActuals(completedPomodoros: 2, sessionCount: 2, focusedSeconds: 50 * 60))
        // Without stored all-time actuals, the week's stand in.
        #expect(report.topTasks[0].allTime == report.topTasks[0].week)
        #expect(report.topTasks[1].allTime.completedPomodoros == 4)
        #expect(report.topTasks[1].estimatePomodoros == 3)
        // 11 October is a focus day, so the streak runs from it through the 16th, with today pending.
        #expect(report.streak == Streak(current: 6, best: 6))
        #expect(!report.isEmpty)
    }

    @Test func emptyWeekReport() {
        let stats = Stats(calendar: Fixture.utc, firstWeekday: 2)
        let week = stats.week(containing: day(2026, 10, 17))
        let report = stats.weekReport(week, sessions: [], tasks: [:], actuals: [:], focusDays: [], today: day(2026, 10, 17))
        #expect(report.isEmpty)
        #expect(report.days.count == 7)
        #expect(report.totalSeconds == 0)
        #expect(report.topTasks.isEmpty)
        #expect(report.streak == .zero)
    }

    static let durations: [(TimeInterval, String)] = [
        (0, "0m"), (59, "0m"), (60, "1m"), (2700, "45m"), (3599, "59m"),
        (3600, "1h"), (6000, "1h 40m"), (7530, "2h 5m"), (-5, "0m"), (.infinity, "0m"),
    ]

    @Test(arguments: durations)
    func durationText(seconds: TimeInterval, text: String) {
        #expect(Stats.durationText(seconds) == text)
    }
}
