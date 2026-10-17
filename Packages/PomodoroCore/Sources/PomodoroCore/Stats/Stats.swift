import Foundation

/// Focus time per day and week, per-task actuals, and the daily streak.
///
/// Pure: every figure comes from the sessions passed in, on the day boundaries of `calendar`.
/// A session counts toward the day it started on, by its active time (pauses excluded,
/// overtime included). Days are `CivilDay`s, so a 23- or 25-hour DST day is still one day.
public struct Stats: Hashable, Sendable {
    public let calendar: Calendar
    /// 1 = Sunday … 7 = Saturday.
    public let firstWeekday: Int

    /// `firstWeekday` outside 1…7, such as `nil` or 0, follows `calendar`'s own.
    public init(calendar: Calendar, firstWeekday: Int? = nil) {
        self.calendar = calendar
        if let firstWeekday, (1...7).contains(firstWeekday) {
            self.firstWeekday = firstWeekday
        } else {
            self.firstWeekday = calendar.firstWeekday
        }
    }

    // MARK: - Days and weeks

    public func day(containing date: Date) -> CivilDay {
        CivilDay(containing: date, in: calendar)
    }

    public func day(of session: FocusSession) -> CivilDay {
        day(containing: session.start)
    }

    public func week(containing day: CivilDay) -> StatsWeek {
        StatsWeek(start: day.adding(days: -((day.weekday - firstWeekday + 7) % 7)))
    }

    public func week(containing date: Date) -> StatsWeek {
        week(containing: day(containing: date))
    }

    /// `count` consecutive days ending on `day`, oldest first.
    public func days(endingOn day: CivilDay, count: Int) -> [CivilDay] {
        (0..<max(0, count)).reversed().map { day.adding(days: -$0) }
    }

    /// The instants `day` covers in `calendar`'s time zone: 23 or 25 hours across DST.
    public func range(of day: CivilDay) -> Range<Date> {
        day.start(in: calendar)..<day.adding(days: 1).start(in: calendar)
    }

    public func range(of week: StatsWeek) -> Range<Date> {
        week.start.start(in: calendar)..<week.end.start(in: calendar)
    }

    // MARK: - Totals

    /// One entry per day in `days`, in that order, including days with no sessions.
    /// Sessions that started on other days are ignored.
    public func dailyFocus(_ sessions: some Sequence<FocusSession>, on days: [CivilDay]) -> [DayFocus] {
        var totals = Dictionary(days.map { ($0, DayFocus(day: $0)) }, uniquingKeysWith: { first, _ in first })
        for session in sessions {
            totals[day(of: session)]?.add(session)
        }
        return days.compactMap { totals[$0] }
    }

    public func dailyFocus(_ sessions: some Sequence<FocusSession>, in week: StatsWeek) -> [DayFocus] {
        dailyFocus(sessions, on: week.days)
    }

    /// Tasks without sessions are absent; sessions without a task are skipped.
    public func taskActuals(_ sessions: some Sequence<FocusSession>) -> [UUID: TaskActuals] {
        var result: [UUID: TaskActuals] = [:]
        for session in sessions {
            guard let taskID = session.taskID else { continue }
            result[taskID, default: .zero].add(session)
        }
        return result
    }

    // MARK: - Streaks

    /// Days with at least one completed focus.
    public func focusDays(_ sessions: some Sequence<FocusSession>) -> Set<CivilDay> {
        focusDays(completedStarts: sessions.filter(\.completed).map(\.start))
    }

    /// Days containing any of `starts`, which should be completed sessions' starts. Sorted first,
    /// so it costs one calendar lookup per day rather than one per session.
    public func focusDays(completedStarts starts: [Date]) -> Set<CivilDay> {
        var days = Set<CivilDay>()
        var current: Range<Date>?
        for start in starts.sorted() {
            if let current, current.contains(start) { continue }
            let day = day(containing: start)
            days.insert(day)
            current = range(of: day)
        }
        return days
    }

    /// Today still counts toward the current streak before its first focus: a streak only
    /// breaks once a day has ended without one. Days after `today` are ignored.
    public func streak(focusDays: Set<CivilDay>, today: CivilDay) -> Streak {
        var current = 0
        var day = focusDays.contains(today) ? today : today.adding(days: -1)
        while focusDays.contains(day) {
            current += 1
            day = day.adding(days: -1)
        }
        var best = 0
        var run = 0
        var previous: CivilDay?
        for day in focusDays.filter({ $0 <= today }).sorted() {
            run = previous.map { $0.adding(days: 1) == day } == true ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return Streak(current: current, best: max(best, current))
    }

    // MARK: - Reports

    /// `sessions` should cover at least today; others are ignored.
    public func todaySummary(today: CivilDay, sessions: some Sequence<FocusSession>, focusDays: Set<CivilDay>) -> TodaySummary {
        let total = dailyFocus(sessions, on: [today])[0]
        return TodaySummary(
            day: today,
            focusedSeconds: total.focusedSeconds,
            completedPomodoros: total.completedPomodoros,
            streak: streak(focusDays: focusDays, today: today)
        )
    }

    /// `sessions` should cover `week` and the week before it; others are ignored. `tasks` and
    /// `actuals` (all-time, for estimate vs. actual) are looked up for the top tasks; a task
    /// missing from `tasks`, such as a deleted one, is left out.
    public func weekReport(
        _ week: StatsWeek,
        sessions: some Sequence<FocusSession>,
        tasks: [UUID: TaskItem],
        actuals: [UUID: TaskActuals],
        focusDays: Set<CivilDay>,
        today: CivilDay,
        topTaskLimit: Int = 5
    ) -> WeekReport {
        let sessions = Array(sessions)
        let thisWeek = sessions.filter { week.contains(day(of: $0)) }
        let previousWeek = dailyFocus(sessions, in: week.previous)
        let topTasks = taskActuals(thisWeek)
            .compactMap { entry -> TaskStat? in
                guard let task = tasks[entry.key] else { return nil }
                return TaskStat(task: task, week: entry.value, allTime: actuals[entry.key] ?? entry.value)
            }
            .sorted { lhs, rhs in
                if lhs.week.focusedSeconds != rhs.week.focusedSeconds { return lhs.week.focusedSeconds > rhs.week.focusedSeconds }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return WeekReport(
            week: week,
            today: today,
            days: dailyFocus(thisWeek, in: week),
            previousWeekSeconds: previousWeek.reduce(0) { $0 + $1.focusedSeconds },
            topTasks: Array(topTasks.prefix(max(0, topTaskLimit))),
            streak: streak(focusDays: focusDays, today: today)
        )
    }

    // MARK: - Formatting

    /// "0m", "45m", "2h", "1h 40m". Rounds down, so 59 minutes and 59 seconds never reads "1h".
    public static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = seconds.isFinite ? max(0, Int(seconds / 60)) : 0
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}

/// Seven consecutive civil days from `start`.
public struct StatsWeek: Hashable, Sendable {
    public let start: CivilDay

    public init(start: CivilDay) {
        self.start = start
    }

    public var days: [CivilDay] { (0..<7).map { start.adding(days: $0) } }
    /// The day after the week's last one.
    public var end: CivilDay { start.adding(days: 7) }
    public var last: CivilDay { start.adding(days: 6) }
    public var previous: StatsWeek { StatsWeek(start: start.adding(days: -7)) }
    public var next: StatsWeek { StatsWeek(start: end) }

    public func contains(_ day: CivilDay) -> Bool {
        start <= day && day < end
    }
}

public struct DayFocus: Hashable, Sendable, Identifiable {
    public var day: CivilDay
    public var focusedSeconds: TimeInterval
    public var completedPomodoros: Int
    public var sessionCount: Int

    public init(day: CivilDay, focusedSeconds: TimeInterval = 0, completedPomodoros: Int = 0, sessionCount: Int = 0) {
        self.day = day
        self.focusedSeconds = focusedSeconds
        self.completedPomodoros = completedPomodoros
        self.sessionCount = sessionCount
    }

    public var id: CivilDay { day }

    mutating func add(_ session: FocusSession) {
        focusedSeconds += session.activeSeconds
        completedPomodoros += session.completed ? 1 : 0
        sessionCount += 1
    }
}

extension TaskActuals {
    mutating func add(_ session: FocusSession) {
        focusedSeconds += session.activeSeconds
        completedPomodoros += session.completed ? 1 : 0
        sessionCount += 1
    }
}

/// Consecutive days with at least one completed focus.
public struct Streak: Hashable, Sendable {
    /// Ends today, or yesterday while today has no focus yet.
    public var current: Int
    /// The longest run ever, the current one included.
    public var best: Int

    public init(current: Int = 0, best: Int = 0) {
        self.current = current
        self.best = best
    }

    public static let zero = Streak()
}

public struct TodaySummary: Hashable, Sendable {
    public var day: CivilDay
    public var focusedSeconds: TimeInterval
    public var completedPomodoros: Int
    public var streak: Streak

    public init(day: CivilDay, focusedSeconds: TimeInterval = 0, completedPomodoros: Int = 0, streak: Streak = .zero) {
        self.day = day
        self.focusedSeconds = focusedSeconds
        self.completedPomodoros = completedPomodoros
        self.streak = streak
    }
}

/// A task's focus in one week, beside its all-time actuals for estimate vs. actual.
public struct TaskStat: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var estimatePomodoros: Int?
    public var isDone: Bool
    public var week: TaskActuals
    public var allTime: TaskActuals

    public init(task: TaskItem, week: TaskActuals, allTime: TaskActuals) {
        id = task.id
        title = task.title
        estimatePomodoros = task.estimatePomodoros
        isDone = task.isDone
        self.week = week
        self.allTime = allTime
    }
}

public struct WeekReport: Hashable, Sendable {
    public var week: StatsWeek
    /// The day the report was made on, for highlighting it and for the streak.
    public var today: CivilDay
    /// One per day of `week`, in order.
    public var days: [DayFocus]
    public var previousWeekSeconds: TimeInterval
    /// Most focused first.
    public var topTasks: [TaskStat]
    public var streak: Streak

    public init(
        week: StatsWeek, today: CivilDay, days: [DayFocus], previousWeekSeconds: TimeInterval = 0,
        topTasks: [TaskStat] = [], streak: Streak = .zero
    ) {
        self.week = week
        self.today = today
        self.days = days
        self.previousWeekSeconds = previousWeekSeconds
        self.topTasks = topTasks
        self.streak = streak
    }

    public var totalSeconds: TimeInterval { days.reduce(0) { $0 + $1.focusedSeconds } }
    public var completedPomodoros: Int { days.reduce(0) { $0 + $1.completedPomodoros } }
    public var isEmpty: Bool { days.allSatisfy { $0.sessionCount == 0 } }
}
