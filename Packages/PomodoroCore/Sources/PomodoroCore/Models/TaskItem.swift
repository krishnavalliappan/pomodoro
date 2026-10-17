import Foundation
import GRDB

public struct TaskItem: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var estimatePomodoros: Int?
    public var tag: String?
    public var isDone: Bool
    public var doneAt: Date?
    public var sortIndex: Int
    public var createdAt: Date
    /// Start of the scheduled day; `nil` means the task lives in the inbox.
    public var scheduledDay: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        estimatePomodoros: Int? = nil,
        tag: String? = nil,
        isDone: Bool = false,
        doneAt: Date? = nil,
        sortIndex: Int = 0,
        createdAt: Date,
        scheduledDay: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.estimatePomodoros = estimatePomodoros
        self.tag = tag
        self.isDone = isDone
        self.doneAt = doneAt
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.scheduledDay = scheduledDay
    }
}

extension TaskItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task"

    // Reference-date seconds round-trip `Date` exactly and let SQL do arithmetic on them.
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSinceReferenceDate
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let isDone = Column(CodingKeys.isDone)
        static let doneAt = Column(CodingKeys.doneAt)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let createdAt = Column(CodingKeys.createdAt)
        static let scheduledDay = Column(CodingKeys.scheduledDay)
    }
}
