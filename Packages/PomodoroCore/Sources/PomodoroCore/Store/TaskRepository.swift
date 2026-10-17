import Foundation
import GRDB

public struct TaskRepository: Sendable {
    let database: AppDatabase

    private var writer: any DatabaseWriter { database.writer }
    private var calendar: Calendar { database.calendar }

    /// Inserts a new task at the end of the list.
    @discardableResult
    public func create(
        title: String,
        notes: String = "",
        estimatePomodoros: Int? = nil,
        tag: String? = nil,
        scheduledDay: Date? = nil,
        createdAt: Date = Date()
    ) throws -> TaskItem {
        try writer.write { db in
            let maxIndex = try TaskItem.select(max(TaskItem.Columns.sortIndex), as: Int.self).fetchOne(db)
            let task = normalized(TaskItem(
                title: title,
                notes: notes,
                estimatePomodoros: estimatePomodoros,
                tag: tag,
                sortIndex: (maxIndex ?? -1) + 1,
                createdAt: createdAt,
                scheduledDay: scheduledDay
            ))
            try task.insert(db)
            return task
        }
    }

    public func insert(_ task: TaskItem) throws {
        try writer.write { db in try normalized(task).insert(db) }
    }

    public func update(_ task: TaskItem) throws {
        try writer.write { db in
            do {
                try normalized(task).update(db)
            } catch RecordError.recordNotFound {
                throw StoreError.notFound(task.id)
            }
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try writer.write { db in try TaskItem.deleteOne(db, key: id) }
    }

    public func fetch(id: UUID) throws -> TaskItem? {
        try writer.read { db in try TaskItem.fetchOne(db, key: id) }
    }

    public func all() throws -> [TaskItem] {
        try writer.read { db in try TaskItem.all().inListOrder().fetchAll(db) }
    }

    @discardableResult
    public func setDone(id: UUID, _ isDone: Bool, at date: Date = Date()) throws -> TaskItem {
        try modify(id: id) { task in
            task.isDone = isDone
            task.doneAt = isDone ? date : nil
        }
    }

    /// Moves a task to a day (normalized to its start) or back to the inbox with `nil`.
    @discardableResult
    public func schedule(id: UUID, on day: Date?) throws -> TaskItem {
        try modify(id: id) { $0.scheduledDay = day }
    }

    /// Assigns `sortIndex` 0, 1, 2… in the given order. IDs not listed keep their index.
    public func reorder(_ orderedIDs: [UUID]) throws {
        try writer.write { db in
            for (index, id) in orderedIDs.enumerated() {
                try TaskItem
                    .filter(key: id)
                    .updateAll(db, TaskItem.Columns.sortIndex.set(to: index))
            }
        }
    }

    /// Tasks scheduled for the day containing `now`, plus unfinished tasks from earlier
    /// days so nothing silently drops off the list.
    public func today(now: Date = Date()) throws -> [TaskItem] {
        try writer.read { db in try todayRequest(now: now).fetchAll(db) }
    }

    /// Unscheduled tasks: open ones, plus ones finished today so check-offs stay visible.
    public func inbox(now: Date = Date()) throws -> [TaskItem] {
        try writer.read { db in try inboxRequest(now: now).fetchAll(db) }
    }

    /// `now` is captured once; re-subscribe after midnight to roll the day over.
    public func observeToday(now: Date = Date()) -> AsyncStream<[TaskItem]> {
        database.observe { db in try todayRequest(now: now).fetchAll(db) }
    }

    public func observeInbox(now: Date = Date()) -> AsyncStream<[TaskItem]> {
        database.observe { db in try inboxRequest(now: now).fetchAll(db) }
    }

    public func observeAll() -> AsyncStream<[TaskItem]> {
        database.observe { db in try TaskItem.all().inListOrder().fetchAll(db) }
    }

    // MARK: - Private

    private func todayRequest(now: Date) -> QueryInterfaceRequest<TaskItem> {
        let day = database.dayRange(containing: now)
        let scheduledToday = TaskItem.Columns.scheduledDay >= day.lowerBound.sqlValue
            && TaskItem.Columns.scheduledDay < day.upperBound.sqlValue
        let overdue = TaskItem.Columns.scheduledDay < day.lowerBound.sqlValue
            && TaskItem.Columns.isDone == false
        return TaskItem.filter(scheduledToday || overdue).inListOrder()
    }

    private func inboxRequest(now: Date) -> QueryInterfaceRequest<TaskItem> {
        let day = database.dayRange(containing: now)
        return TaskItem
            .filter(TaskItem.Columns.scheduledDay == nil)
            .filter(TaskItem.Columns.isDone == false || TaskItem.Columns.doneAt >= day.lowerBound.sqlValue)
            .inListOrder()
    }

    private func normalized(_ task: TaskItem) -> TaskItem {
        var task = task
        task.scheduledDay = task.scheduledDay.map { calendar.startOfDay(for: $0) }
        return task
    }

    private func modify(id: UUID, _ change: @Sendable (inout TaskItem) -> Void) throws -> TaskItem {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            change(&task)
            task = normalized(task)
            try task.update(db)
            return task
        }
    }
}

extension QueryInterfaceRequest where RowDecoder == TaskItem {
    func inListOrder() -> Self {
        order(TaskItem.Columns.sortIndex, TaskItem.Columns.createdAt)
    }
}
