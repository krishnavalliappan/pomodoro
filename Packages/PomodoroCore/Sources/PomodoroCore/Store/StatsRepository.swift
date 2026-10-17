import Foundation
import GRDB

/// Reads what `Stats` needs in one database read, so a caller can run it off the main thread.
public struct StatsRepository: Sendable {
    let database: AppDatabase

    /// Day boundaries follow the store's calendar.
    public func stats(firstWeekday: Int? = nil) -> Stats {
        Stats(calendar: database.calendar, firstWeekday: firstWeekday)
    }

    public func todaySummary(now: Date) throws -> TodaySummary {
        let stats = stats()
        return try database.writer.read { db in try Self.todaySummary(db, stats: stats, now: now) }
    }

    public func weekReport(_ week: StatsWeek, stats: Stats, now: Date) throws -> WeekReport {
        try database.writer.read { db in try Self.weekReport(db, week: week, stats: stats, now: now) }
    }

    /// Focus per day for the `count` days ending today, oldest first, empty days included.
    public func recentDays(_ count: Int, now: Date) throws -> [DayFocus] {
        let stats = stats()
        let days = stats.days(endingOn: stats.day(containing: now), count: count)
        guard let first = days.first, let last = days.last else { return [] }
        let range = stats.range(of: first).lowerBound..<stats.range(of: last).upperBound
        let sessions = try database.writer.read { db in try Self.started(in: range).fetchAll(db) }
        return stats.dailyFocus(sessions, on: days)
    }

    /// Emits the report for `week`, then a fresh one after each change to sessions or tasks.
    /// "Today", for the highlight and the streak, is fixed at `now`; subscribe again for a new day.
    public func observeWeekReport(_ week: StatsWeek, stats: Stats, now: Date) -> AsyncStream<WeekReport> {
        database.observe { db in try Self.weekReport(db, week: week, stats: stats, now: now) }
    }

    // MARK: - Private

    static func todaySummary(_ db: Database, stats: Stats, now: Date) throws -> TodaySummary {
        let today = stats.day(containing: now)
        let sessions = try started(in: stats.range(of: today)).fetchAll(db)
        return stats.todaySummary(today: today, sessions: sessions, focusDays: try focusDays(db, stats: stats))
    }

    static func weekReport(_ db: Database, week: StatsWeek, stats: Stats, now: Date) throws -> WeekReport {
        let range = stats.range(of: week.previous).lowerBound..<stats.range(of: week).upperBound
        let sessions = try started(in: range).fetchAll(db)
        let thisWeek = stats.range(of: week)
        let taskIDs = Set(sessions.filter { thisWeek.contains($0.start) }.compactMap(\.taskID))
        let tasks = try TaskItem.fetchAll(db, keys: taskIDs)
        return stats.weekReport(
            week,
            sessions: sessions,
            tasks: Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            actuals: try FocusSessionRepository.actuals(db, taskIDs: Array(taskIDs)),
            focusDays: try focusDays(db, stats: stats),
            today: stats.day(containing: now)
        )
    }

    /// Only the start column of completed sessions: a streak spans all of history.
    private static func focusDays(_ db: Database, stats: Stats) throws -> Set<CivilDay> {
        let starts = try Double.fetchAll(db, sql: """
            SELECT start FROM \(FocusSession.databaseTableName) WHERE completed ORDER BY start
            """)
        return stats.focusDays(completedStarts: starts.map(Date.init(timeIntervalSinceReferenceDate:)))
    }

    private static func started(in range: Range<Date>) -> QueryInterfaceRequest<FocusSession> {
        FocusSession
            .filter(FocusSession.Columns.start >= range.lowerBound.sqlValue)
            .filter(FocusSession.Columns.start < range.upperBound.sqlValue)
            .order(FocusSession.Columns.start)
    }
}
