import Foundation
import GRDB

public struct TimeBlock: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var taskID: UUID?
    public var title: String
    public var start: Date
    public var duration: TimeInterval
    /// Free-form color token chosen by the UI (e.g. a hex string or palette name).
    public var color: String?

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        title: String,
        start: Date,
        duration: TimeInterval,
        color: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.start = start
        self.duration = duration
        self.color = color
    }

    public var end: Date { start.addingTimeInterval(duration) }

    /// Half-open: a block ending at 10:00 does not contain 10:00.
    public func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

extension TimeBlock: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "timeBlock"

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let taskID = Column(CodingKeys.taskID)
        static let start = Column(CodingKeys.start)
        static let duration = Column(CodingKeys.duration)
    }
}
