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
                "plannedSeconds", "overtimeSeconds", "completed",
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
                try FocusSession(start: start, end: start.addingTimeInterval(-1), plannedSeconds: 1500, completed: false)
                    .insert($0)
            }
        }
        #expect(throws: DatabaseError.self) {
            try db.writer.write {
                try FocusSession(taskID: UUID(), start: start, end: start, plannedSeconds: 1500, completed: false)
                    .insert($0)
            }
        }
    }

    @Test func datesRoundTripWithSubSecondPrecision() throws {
        let db = try Fixture.database()
        let start = Date(timeIntervalSinceReferenceDate: 813_692_800.123456)
        let session = FocusSession(
            start: start, end: start.addingTimeInterval(1500.5), plannedSeconds: 1500, overtimeSeconds: 0.5,
            completed: true
        )
        try db.sessions.insert(session)
        #expect(try db.sessions.fetch(id: session.id) == session)
    }
}
