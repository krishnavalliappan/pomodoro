import Foundation
import GRDB

/// Time actually spent on a task, overtime included.
public struct TaskActuals: Hashable, Sendable {
    public var completedPomodoros: Int
    public var sessionCount: Int
    public var focusedSeconds: TimeInterval

    public init(completedPomodoros: Int = 0, sessionCount: Int = 0, focusedSeconds: TimeInterval = 0) {
        self.completedPomodoros = completedPomodoros
        self.sessionCount = sessionCount
        self.focusedSeconds = focusedSeconds
    }

    public static let zero = TaskActuals()
}

/// Focus totals for one calendar day. A session counts toward the day it started on.
public struct DayTotal: Hashable, Sendable {
    /// Start of the day in the store's calendar.
    public var day: Date
    public var completedPomodoros: Int
    public var sessionCount: Int
    public var focusedSeconds: TimeInterval

    public init(day: Date, completedPomodoros: Int = 0, sessionCount: Int = 0, focusedSeconds: TimeInterval = 0) {
        self.day = day
        self.completedPomodoros = completedPomodoros
        self.sessionCount = sessionCount
        self.focusedSeconds = focusedSeconds
    }
}

public struct FocusSessionRepository: Sendable {
    let database: AppDatabase

    private var writer: any DatabaseWriter { database.writer }

    public func insert(_ session: FocusSession) throws {
        try writer.write { db in try session.insert(db) }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try writer.write { db in try FocusSession.deleteOne(db, key: id) }
    }

    public func fetch(id: UUID) throws -> FocusSession? {
        try writer.read { db in try FocusSession.fetchOne(db, key: id) }
    }

    /// Sessions that started within `range`, oldest first.
    public func sessions(in range: Range<Date>) throws -> [FocusSession] {
        try writer.read { db in try Self.started(in: range).fetchAll(db) }
    }

    public func sessions(forTask taskID: UUID) throws -> [FocusSession] {
        try writer.read { db in
            try FocusSession
                .filter(FocusSession.Columns.taskID == taskID)
                .order(FocusSession.Columns.start)
                .fetchAll(db)
        }
    }

    public func actuals(forTask taskID: UUID) throws -> TaskActuals {
        try actuals(forTasks: [taskID])[taskID] ?? .zero
    }

    /// Batched so a task list can load every row's actuals in one query.
    /// Tasks without sessions are absent from the result.
    public func actuals(forTasks taskIDs: some Collection<UUID>) throws -> [UUID: TaskActuals] {
        let ids = Array(taskIDs)
        return try writer.read { db in try Self.actuals(db, taskIDs: ids) }
    }

    public func observeActuals(forTasks taskIDs: some Collection<UUID>) -> AsyncStream<[UUID: TaskActuals]> {
        let ids = Array(taskIDs)
        return database.observe { db in try Self.actuals(db, taskIDs: ids) }
    }

    /// One entry per calendar day in `range`, including days with no sessions.
    public func dailyTotals(in range: Range<Date>) throws -> [DayTotal] {
        try writer.read { db in try dailyTotals(db, in: range) }
    }

    public func total(onDayContaining date: Date) throws -> DayTotal {
        let range = database.dayRange(containing: date)
        return try dailyTotals(in: range).first ?? DayTotal(day: range.lowerBound)
    }

    public func observeDailyTotals(in range: Range<Date>) -> AsyncStream<[DayTotal]> {
        database.observe { db in try dailyTotals(db, in: range) }
    }

    // MARK: - Private

    private static func started(in range: Range<Date>) -> QueryInterfaceRequest<FocusSession> {
        FocusSession
            .filter(FocusSession.Columns.start >= range.lowerBound.sqlValue)
            .filter(FocusSession.Columns.start < range.upperBound.sqlValue)
            .order(FocusSession.Columns.start)
    }

    private static func actuals(_ db: Database, taskIDs: [UUID]) throws -> [UUID: TaskActuals] {
        guard !taskIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT taskID,
                   TOTAL(completed) AS completedPomodoros,
                   COUNT(*) AS sessionCount,
                   TOTAL("end" - "start") AS focusedSeconds
            FROM \(FocusSession.databaseTableName)
            WHERE taskID IN (\(databaseQuestionMarks(count: taskIDs.count)))
            GROUP BY taskID
            """, arguments: StatementArguments(taskIDs))
        var result: [UUID: TaskActuals] = [:]
        for row in rows {
            let id: UUID = row["taskID"]
            result[id] = TaskActuals(
                completedPomodoros: Int(row["completedPomodoros"] as Double),
                sessionCount: row["sessionCount"],
                focusedSeconds: row["focusedSeconds"]
            )
        }
        return result
    }

    // Grouped in Swift because day boundaries depend on the calendar's time zone and DST.
    private func dailyTotals(_ db: Database, in range: Range<Date>) throws -> [DayTotal] {
        guard !range.isEmpty else { return [] }
        let calendar = database.calendar
        var day = calendar.startOfDay(for: range.lowerBound)
        var totals: [Date: DayTotal] = [:]
        var days: [Date] = []
        while day < range.upperBound {
            days.append(day)
            totals[day] = DayTotal(day: day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        for session in try Self.started(in: range).fetchAll(db) {
            let key = calendar.startOfDay(for: session.start)
            totals[key]?.sessionCount += 1
            totals[key]?.completedPomodoros += session.completed ? 1 : 0
            totals[key]?.focusedSeconds += session.duration
        }
        return days.compactMap { totals[$0] }
    }
}
