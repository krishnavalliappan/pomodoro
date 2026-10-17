import Foundation
import GRDB
import Testing
@testable import PomodoroCore

struct AppDatabaseTests {
    @Test func migratorCreatesV1Schema() throws {
        let db = try Fixture.database()
        try db.writer.read { db in
            #expect(try AppDatabase.migrator.appliedMigrations(db) == ["v1"])
            #expect(try db.tableExists("task"))
            #expect(try db.tableExists("timeBlock"))
            #expect(try db.tableExists("focusSession"))
            let sessionColumns = try db.columns(in: "focusSession").map(\.name)
            #expect(sessionColumns == [
                "id", "taskID", "blockID", "start", "end",
                "plannedSeconds", "activeSeconds", "pausedSeconds", "overtimeSeconds", "completed",
            ])
        }
    }

    @Test func migratingTwiceIsANoOp() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue, calendar: Fixture.utc)
        _ = try AppDatabase(queue, calendar: Fixture.utc)
        let applied = try queue.read { try AppDatabase.migrator.appliedMigrations($0) }
        #expect(applied == ["v1"])
    }

    @Test func onDiskCreatesDirectoryAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/db.sqlite")

        let first = try AppDatabase.onDisk(at: url, calendar: Fixture.utc)
        let task = try first.tasks.create(title: "Persist me", createdAt: Fixture.date(day: 17, 9))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let second = try AppDatabase.onDisk(at: url, calendar: Fixture.utc)
        #expect(try second.tasks.fetch(id: task.id) == task)
    }

    @Test func scheduledDaySurvivesReopeningInAnotherTimeZone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PomodoroStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("db.sqlite")
        let newYork = Fixture.calendar("America/New_York")
        let losAngeles = Fixture.calendar("America/Los_Angeles")
        let october18 = CivilDay(year: 2026, month: 10, day: 18)

        let east = try AppDatabase.onDisk(at: url, calendar: newYork)
        let task = try east.tasks.create(title: "Trip", createdAt: Fixture.date(day: 17, 9, calendar: newYork))
        try east.tasks.schedule(id: task.id, onDayContaining: Fixture.date(day: 18, 0, 30, calendar: newYork))
        #expect(try east.tasks.fetch(id: task.id)?.scheduledDay == october18)

        let west = try AppDatabase.onDisk(at: url, calendar: losAngeles)
        #expect(try west.tasks.fetch(id: task.id)?.scheduledDay == october18)
        #expect(try west.tasks.today(now: Fixture.date(day: 17, 22, calendar: losAngeles)).isEmpty)
        #expect(try west.tasks.today(now: Fixture.date(day: 18, 9, calendar: losAngeles)).map(\.id) == [task.id])

        // An unrelated edit must not re-derive (and shift) the day.
        var renamed = try #require(try west.tasks.fetch(id: task.id))
        renamed.title = "Trip west"
        try west.tasks.update(renamed)
        try west.tasks.setDone(id: task.id, false, at: Fixture.date(day: 17, 22, calendar: losAngeles))
        #expect(try west.tasks.fetch(id: task.id)?.scheduledDay == october18)
        #expect(try east.tasks.fetch(id: task.id)?.scheduledDay == october18)
    }

    @Test func scheduledDayIsStoredAsISOText() throws {
        let db = try Fixture.database()
        let task = try db.tasks.create(
            title: "T", scheduledDay: CivilDay(year: 2026, month: 3, day: 7), createdAt: Fixture.date(day: 17)
        )
        let raw = try db.writer.read { db in
            try String.fetchOne(db, sql: "SELECT scheduledDay FROM task WHERE id = ?", arguments: [task.id])
        }
        #expect(raw == "2026-03-07")
    }

    @Test func defaultURLIsInApplicationSupport() throws {
        let url = try AppDatabase.defaultURL()
        #expect(url.lastPathComponent == "db.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Pomodoro")
        #expect(url.path.contains("Application Support"))
    }

    @Test func schemaRejectsInvalidRows() throws {
        let db = try Fixture.database()
        let start = Fixture.date(day: 17, 9)
        // Bypass repository validation to prove the schema itself guards the data.
        #expect(throws: DatabaseError.self) {
            try db.writer.write { try TimeBlock(title: "Zero", start: start, duration: 0).insert($0) }
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write {
                try FocusSession(
                    start: start, end: start.addingTimeInterval(-1), plannedSeconds: 1500, activeSeconds: 0,
                    completed: false
                )
                    .insert($0)
            }
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write {
                try FocusSession(
                    taskID: UUID(), start: start, end: start, plannedSeconds: 1500, activeSeconds: 0, completed: false
                )
                    .insert($0)
            }
        }
    }

    @Test func schemaRejectsInconsistentSessionTiming() throws {
        let db = try Fixture.database()
        let start = Fixture.date(day: 17, 9)
        let end = start.addingTimeInterval(1800)
        let invalid = [
            FocusSession(start: start, end: end, plannedSeconds: 1500, activeSeconds: -1, completed: false),
            FocusSession(start: start, end: end, plannedSeconds: 1500, activeSeconds: 1500, pausedSeconds: -1, completed: false),
            // Active plus paused exceeds the wall-clock span.
            FocusSession(start: start, end: end, plannedSeconds: 1500, activeSeconds: 1700, pausedSeconds: 200, completed: true),
            // Overtime is a subset of active time.
            FocusSession(start: start, end: end, plannedSeconds: 1500, activeSeconds: 100, overtimeSeconds: 200, completed: true),
        ]
        for session in invalid {
            #expect(throws: DatabaseError.self) { try db.writer.write { try session.insert($0) } }
        }
    }

    @Test func datesRoundTripWithSubSecondPrecision() throws {
        let db = try Fixture.database()
        let start = Date(timeIntervalSinceReferenceDate: 813_692_800.123456)
        let session = FocusSession(
            start: start, end: start.addingTimeInterval(1500.5), plannedSeconds: 1500, activeSeconds: 1500.5,
            overtimeSeconds: 0.5,
            completed: true
        )
        try db.sessions.insert(session)
        #expect(try db.sessions.fetch(id: session.id) == session)
    }
}
