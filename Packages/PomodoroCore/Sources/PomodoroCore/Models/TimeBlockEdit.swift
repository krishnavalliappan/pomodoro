import Foundation

/// The fields one change to a block touched. Saved by merging into the row as it is at write
/// time, so a rename can't undo a move committed while its editor was open, nor a move a recolour.
public struct TimeBlockEdit: Equatable, Sendable {
    public var title: String?
    /// `.some(nil)` unlinks; `nil` leaves the link alone.
    public var taskID: UUID??
    public var start: Date?
    public var duration: TimeInterval?
    /// `.some(nil)` goes back to the accent colour; `nil` leaves it alone.
    public var color: String??

    public init(
        title: String? = nil,
        taskID: UUID?? = nil,
        start: Date? = nil,
        duration: TimeInterval? = nil,
        color: String?? = nil
    ) {
        self.title = title
        self.taskID = taskID
        self.start = start
        self.duration = duration
        self.color = color
    }

    public var isEmpty: Bool {
        title == nil && taskID == nil && start == nil && duration == nil && color == nil
    }

    public func applied(to block: TimeBlock) -> TimeBlock {
        var block = block
        if let title { block.title = title }
        if let taskID { block.taskID = taskID }
        if let start { block.start = start }
        if let duration { block.duration = duration }
        if let color { block.color = color }
        return block
    }
}
