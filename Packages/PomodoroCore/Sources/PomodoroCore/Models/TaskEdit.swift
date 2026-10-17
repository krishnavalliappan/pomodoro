import Foundation

/// The fields an inline editor changed. Saved by merging into the row as it is at write time,
/// so a check-off, reorder or reschedule committed meanwhile survives the save.
public struct TaskEdit: Equatable, Sendable {
    public var title: String?
    public var notes: String?
    /// `.some(nil)` clears the estimate; `nil` leaves it alone.
    public var estimatePomodoros: Int??

    public init(title: String? = nil, notes: String? = nil, estimatePomodoros: Int?? = nil) {
        self.title = title
        self.notes = notes
        self.estimatePomodoros = estimatePomodoros
    }

    public var isEmpty: Bool {
        title == nil && notes == nil && estimatePomodoros == nil
    }

    public func applied(to task: TaskItem) -> TaskItem {
        var task = task
        if let title { task.title = title }
        if let notes { task.notes = notes }
        if let estimatePomodoros { task.estimatePomodoros = estimatePomodoros }
        return task
    }
}

/// An inline editor's unsaved text. Fields the user hasn't touched follow the latest row; edited
/// ones keep the edit until it's saved, whatever else changes on the row.
public struct TaskDraft: Equatable, Sendable {
    /// The row the draft was last reconciled with.
    public private(set) var base: TaskItem
    public var title: String
    public var notes: String
    public var estimatePomodoros: Int?

    public init(_ task: TaskItem) {
        base = task
        title = task.title
        notes = task.notes
        estimatePomodoros = task.estimatePomodoros
    }

    /// Takes a newer version of the row.
    public mutating func rebase(onto task: TaskItem) {
        if title == base.title { title = task.title }
        if notes == base.notes { notes = task.notes }
        if estimatePomodoros == base.estimatePomodoros { estimatePomodoros = task.estimatePomodoros }
        base = task
    }

    /// The changed fields, or `nil` when there's nothing to save. A blank title isn't saved:
    /// it would leave a row nobody can find.
    public var edit: TaskEdit? {
        var edit = TaskEdit()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != base.title { edit.title = trimmed }
        if notes != base.notes { edit.notes = notes }
        if estimatePomodoros != base.estimatePomodoros { edit.estimatePomodoros = .some(estimatePomodoros) }
        return edit.isEmpty ? nil : edit
    }
}
