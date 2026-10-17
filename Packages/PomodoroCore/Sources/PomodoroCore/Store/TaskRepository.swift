import Foundation
import GRDB

public struct TaskRepository: Sendable {
    let database: AppDatabase

    private var writer: any DatabaseWriter { database.writer }

    /// Inserts a new task at the end of the list.
    @discardableResult
    public func create(
        title: String,
        notes: String = "",
        estimatePomodoros: Int? = nil,
        tag: String? = nil,
        scheduledDay: CivilDay? = nil,
        createdAt: Date = Date()
    ) throws -> TaskItem {
        try writer.write { db in
            let maxIndex = try TaskItem.select(max(TaskItem.Columns.sortIndex), as: Int.self).fetchOne(db)
            let task = TaskItem(
                title: title,
                notes: notes,
                estimatePomodoros: estimatePomodoros,
                tag: tag,
                sortIndex: (maxIndex ?? -1) + 1,
                createdAt: createdAt,
                scheduledDay: scheduledDay
            )
            try task.insert(db)
            return task
        }
    }

    public func insert(_ task: TaskItem) throws {
        try writer.write { db in try task.insert(db) }
    }

    public func update(_ task: TaskItem) throws {
        try writer.write { db in
            do {
                try task.update(db)
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

    /// Moves a task to a day, or back to the inbox with `nil`.
    @discardableResult
    public func schedule(id: UUID, on day: CivilDay?) throws -> TaskItem {
        try modify(id: id) { $0.scheduledDay = day }
    }

    /// Schedules for the day `date` falls on in the store's calendar, e.g. from a date picker.
    @discardableResult
    public func schedule(id: UUID, onDayContaining date: Date) throws -> TaskItem {
        try schedule(id: id, on: database.day(containing: date))
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
    /// Like `today`, the day is fixed by `now`.
    public func inbox(now: Date = Date()) throws -> [TaskItem] {
        try writer.read { db in try inboxRequest(now: now).fetchAll(db) }
    }

    /// `now` is captured once: the subscriber must re-subscribe at the next midnight, on
    /// wake, and on time-zone or calendar changes to roll the day over.
    public func observeToday(now: Date = Date()) -> AsyncStream<[TaskItem]> {
        database.observe { db in try todayRequest(now: now).fetchAll(db) }
    }

    /// Same day-rollover contract as `observeToday`.
    public func observeInbox(now: Date = Date()) -> AsyncStream<[TaskItem]> {
        database.observe { db in try inboxRequest(now: now).fetchAll(db) }
    }

    public func observeAll() -> AsyncStream<[TaskItem]> {
        database.observe { db in try TaskItem.all().inListOrder().fetchAll(db) }
    }

    /// Today, inbox, upcoming and their actuals, read in one transaction so a task list never
    /// pairs rows with actuals from a different commit. The day is fixed by `now`.
    public func overview(now: Date = Date()) throws -> TaskOverview {
        try writer.read { db in try overview(db, now: now) }
    }

    /// Same day-rollover contract as `observeToday`.
    public func observeOverview(now: Date = Date()) -> AsyncStream<TaskOverview> {
        database.observe { db in try overview(db, now: now) }
    }

    /// Creates the task a quick-add line describes and, when it has a start time, a block
    /// linked to it, in one transaction. `defaultDay` schedules lines that name no day.
    /// Returns `nil` for a blank title.
    @discardableResult
    public func create(
        _ entry: QuickAddResult,
        defaultDay: CivilDay?,
        createdAt: Date = Date()
    ) throws -> (task: TaskItem, block: TimeBlock?)? {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let slot = entry.blockStart.flatMap { start in entry.blockDuration.map { (start: start, duration: $0) } }
        if let slot, !(slot.duration > 0 && slot.duration.isFinite) {
            throw StoreError.invalidDuration(slot.duration)
        }
        return try writer.write { db in
            let maxIndex = try TaskItem.select(max(TaskItem.Columns.sortIndex), as: Int.self).fetchOne(db)
            let task = TaskItem(
                title: title,
                estimatePomodoros: entry.estimate,
                tag: entry.tag,
                sortIndex: (maxIndex ?? -1) + 1,
                createdAt: createdAt,
                scheduledDay: entry.day ?? defaultDay
            )
            try task.insert(db)
            let block = slot.map { TimeBlock(taskID: task.id, title: title, start: $0.start, duration: $0.duration) }
            try block?.insert(db)
            return (task, block)
        }
    }

    // MARK: - Private

    private func overview(_ db: Database, now: Date) throws -> TaskOverview {
        let today = try todayRequest(now: now).fetchAll(db)
        let inbox = try inboxRequest(now: now).fetchAll(db)
        let upcoming = try upcomingRequest(now: now).fetchAll(db)
        let ids = (today + inbox + upcoming).map(\.id)
        return TaskOverview(
            day: database.day(containing: now),
            today: today,
            inbox: inbox,
            upcoming: upcoming,
            actuals: try FocusSessionRepository.actuals(db, taskIDs: ids)
        )
    }

    private func upcomingRequest(now: Date) -> QueryInterfaceRequest<TaskItem> {
        let today = database.day(containing: now)
        return TaskItem
            .filter(TaskItem.Columns.scheduledDay > today && TaskItem.Columns.isDone == false)
            .order(TaskItem.Columns.scheduledDay, TaskItem.Columns.sortIndex, TaskItem.Columns.createdAt)
    }

    // ISO day strings compare chronologically, so SQL can order them directly.
    private func todayRequest(now: Date) -> QueryInterfaceRequest<TaskItem> {
        let today = database.day(containing: now)
        let scheduledToday = TaskItem.Columns.scheduledDay == today
        let overdue = TaskItem.Columns.scheduledDay < today && TaskItem.Columns.isDone == false
        return TaskItem.filter(scheduledToday || overdue).inListOrder()
    }

    private func inboxRequest(now: Date) -> QueryInterfaceRequest<TaskItem> {
        let day = database.dayRange(containing: now)
        return TaskItem
            .filter(TaskItem.Columns.scheduledDay == nil)
            .filter(
                TaskItem.Columns.isDone == false
                    || (TaskItem.Columns.doneAt >= day.lowerBound.sqlValue
                        && TaskItem.Columns.doneAt < day.upperBound.sqlValue)
            )
            .inListOrder()
    }

    private func modify(id: UUID, _ change: @Sendable (inout TaskItem) -> Void) throws -> TaskItem {
        try writer.write { db in
            guard var task = try TaskItem.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            change(&task)
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

/// Everything a task list shows for one day.
public struct TaskOverview: Equatable, Sendable {
    public var day: CivilDay
    /// Scheduled for `day`, plus unfinished ones from earlier days, in list order.
    public var today: [TaskItem]
    /// Unscheduled: open ones, plus ones finished on `day`.
    public var inbox: [TaskItem]
    /// Unfinished tasks scheduled after `day`, soonest first.
    public var upcoming: [TaskItem]
    /// Keyed by task; tasks without sessions are absent.
    public var actuals: [UUID: TaskActuals]

    public init(
        day: CivilDay,
        today: [TaskItem] = [],
        inbox: [TaskItem] = [],
        upcoming: [TaskItem] = [],
        actuals: [UUID: TaskActuals] = [:]
    ) {
        self.day = day
        self.today = today
        self.inbox = inbox
        self.upcoming = upcoming
        self.actuals = actuals
    }

    public func actuals(for id: UUID) -> TaskActuals {
        actuals[id] ?? .zero
    }
}
