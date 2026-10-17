import Foundation
import GRDB

/// A finished focus phase as logged to the store. Built from plain fields so the
/// timer engine's own record type can be bridged without depending on it.
public struct FocusSession: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID?
    public var blockID: UUID?
    public var start: Date
    public var end: Date
    public var plannedSeconds: TimeInterval
    public var overtimeSeconds: TimeInterval
    /// `false` when the session was stopped before the planned duration elapsed.
    public var completed: Bool

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        blockID: UUID? = nil,
        start: Date,
        end: Date,
        plannedSeconds: TimeInterval,
        overtimeSeconds: TimeInterval = 0,
        completed: Bool
    ) {
        self.id = id
        self.taskID = taskID
        self.blockID = blockID
        self.start = start
        self.end = end
        self.plannedSeconds = plannedSeconds
        self.overtimeSeconds = overtimeSeconds
        self.completed = completed
    }

    /// Wall-clock length of the session, overtime included.
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

extension FocusSession: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "focusSession"

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskID = Column(CodingKeys.taskID)
        static let blockID = Column(CodingKeys.blockID)
        static let start = Column(CodingKeys.start)
        static let end = Column(CodingKeys.end)
        static let completed = Column(CodingKeys.completed)
    }
}
