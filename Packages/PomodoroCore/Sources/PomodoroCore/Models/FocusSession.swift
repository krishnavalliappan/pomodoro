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
    /// Time spent focusing: pauses excluded, overtime included. Actuals and totals sum this.
    public var activeSeconds: TimeInterval
    public var pausedSeconds: TimeInterval
    /// Already part of `activeSeconds`; kept separately for stats.
    public var overtimeSeconds: TimeInterval
    /// Maps from the timer's outcome: `.completed` is `true`, `.abandoned` is `false`.
    public var completed: Bool

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        blockID: UUID? = nil,
        start: Date,
        end: Date,
        plannedSeconds: TimeInterval,
        activeSeconds: TimeInterval,
        pausedSeconds: TimeInterval = 0,
        overtimeSeconds: TimeInterval = 0,
        completed: Bool
    ) {
        self.id = id
        self.taskID = taskID
        self.blockID = blockID
        self.start = start
        self.end = end
        self.plannedSeconds = plannedSeconds
        self.activeSeconds = activeSeconds
        self.pausedSeconds = pausedSeconds
        self.overtimeSeconds = overtimeSeconds
        self.completed = completed
    }

    /// Slack for `activeSeconds + pausedSeconds` vs. wall-clock length, which the timer
    /// computes separately and can differ by floating-point rounding.
    public static let timingTolerance: TimeInterval = 0.001

    /// `true` when timing fields are finite, nonnegative and fit within `start..<end`.
    public var hasValidTiming: Bool {
        let fields = [plannedSeconds, activeSeconds, pausedSeconds, overtimeSeconds]
        guard fields.allSatisfy({ $0.isFinite && $0 >= 0 }), duration >= 0 else { return false }
        return overtimeSeconds <= activeSeconds
            && activeSeconds + pausedSeconds <= duration + Self.timingTolerance
    }

    /// Wall-clock length of the session, pauses included. Not focus time; see `activeSeconds`.
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

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let taskID = Column(CodingKeys.taskID)
        public static let blockID = Column(CodingKeys.blockID)
        public static let start = Column(CodingKeys.start)
        public static let end = Column(CodingKeys.end)
        public static let activeSeconds = Column(CodingKeys.activeSeconds)
        public static let completed = Column(CodingKeys.completed)
    }
}
