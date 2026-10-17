import Foundation
import GRDB

/// Owns the SQLite connection and schema. Repositories are cheap value views onto it.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// Defines day boundaries for "today", per-day totals and scheduled days.
    public let calendar: Calendar

    public init(_ writer: any DatabaseWriter, calendar: Calendar = .autoupdatingCurrent) throws {
        self.writer = writer
        self.calendar = calendar
        try Self.migrator.migrate(writer)
    }

    public static func inMemory(calendar: Calendar = .autoupdatingCurrent) throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(), calendar: calendar)
    }

    /// Opens (creating if needed) the database at `url`, defaulting to
    /// `Application Support/Pomodoro/db.sqlite`.
    public static func onDisk(at url: URL? = nil, calendar: Calendar = .autoupdatingCurrent) throws -> AppDatabase {
        let url = try url ?? defaultURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(DatabasePool(path: url.path), calendar: calendar)
    }

    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pomodoro", isDirectory: true)
            .appendingPathComponent("db.sqlite")
    }

    public var tasks: TaskRepository { TaskRepository(database: self) }
    public var blocks: TimeBlockRepository { TimeBlockRepository(database: self) }
    public var sessions: FocusSessionRepository { FocusSessionRepository(database: self) }

    // Never edit a shipped migration; append a new one instead.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: TaskItem.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("estimatePomodoros", .integer).check { $0 >= 0 }
                t.column("tag", .text)
                t.column("isDone", .boolean).notNull().defaults(to: false)
                t.column("doneAt", .double)
                t.column("sortIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .double).notNull()
                // `YYYY-MM-DD`, not an instant, so the day survives time-zone changes.
                t.column("scheduledDay", .text).indexed()
            }

            try db.create(table: TimeBlock.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("taskID", .blob)
                    .indexed()
                    .references(TaskItem.databaseTableName, onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("start", .double).notNull().indexed()
                t.column("duration", .double).notNull().check { $0 > 0 }
                t.column("color", .text)
            }

            // Sessions are history: deleting a task or block keeps its time, just unlinked.
            try db.create(table: FocusSession.databaseTableName) { t in
                t.primaryKey("id", .blob)
                t.column("taskID", .blob)
                    .indexed()
                    .references(TaskItem.databaseTableName, onDelete: .setNull)
                t.column("blockID", .blob)
                    .indexed()
                    .references(TimeBlock.databaseTableName, onDelete: .setNull)
                t.column("start", .double).notNull().indexed()
                t.column("end", .double).notNull()
                t.column("plannedSeconds", .double).notNull().check { $0 >= 0 }
                t.column("activeSeconds", .double).notNull().check { $0 >= 0 }
                t.column("pausedSeconds", .double).notNull().defaults(to: 0).check { $0 >= 0 }
                t.column("overtimeSeconds", .double).notNull().defaults(to: 0).check { $0 >= 0 }
                t.column("completed", .boolean).notNull()
                t.check(Column("end") >= Column("start"))
                t.check(Column("overtimeSeconds") <= Column("activeSeconds"))
                // Active and paused time partition the session; allow float rounding slack.
                t.check(
                    Column("activeSeconds") + Column("pausedSeconds")
                        <= Column("end") - Column("start") + FocusSession.timingTolerance
                )
            }
        }
        return migrator
    }

    /// Bridges a GRDB `ValueObservation` to an `AsyncStream` the UI can iterate.
    /// Emits the current value first, then a fresh value after each relevant commit.
    /// Only the newest value is buffered: these are current-state snapshots, so a slow
    /// consumer should skip stale ones. The stream finishes if the fetch throws.
    func observe<Value: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncStream<Value> {
        let writer = self.writer
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let values = ValueObservation.tracking(fetch)
                        .values(in: writer, bufferingPolicy: .bufferingNewest(1))
                    for try await value in values {
                        continuation.yield(value)
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The civil day `date` falls on in the store's calendar.
    public func day(containing date: Date) -> CivilDay {
        CivilDay(containing: date, in: calendar)
    }

    func dayRange(containing date: Date) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start..<end
    }
}

public enum StoreError: Error, Equatable, Sendable {
    case notFound(UUID)
    case invalidDuration(TimeInterval)
    /// Timing fields are negative, non-finite, or don't fit between start and end.
    case invalidSession(UUID)
}

extension Date {
    /// Matches the records' `.timeIntervalSinceReferenceDate` storage, for use in SQL filters.
    var sqlValue: Double { timeIntervalSinceReferenceDate }
}
