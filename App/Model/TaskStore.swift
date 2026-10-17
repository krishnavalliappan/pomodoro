import Foundation
import Observation
import PomodoroCore
import os

/// The task lists every view reads, kept live by one database observation.
///
/// Separate from `AppModel` so a task change never invalidates the timer's views, and the 1 Hz
/// readout never touches the task rows. Reads happen on GRDB's queue; the small writes behind
/// a click run inline.
@MainActor
@Observable
final class TaskStore {
    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "tasks")

    private(set) var overview: TaskOverview
    /// The task of the block scheduled now, refreshed when the popover opens.
    private(set) var suggestedTaskID: UUID? = nil

    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored private let clock: any TimeSource
    @ObservationIgnored private let observation = Subscription()
    /// Bumped per subscription, so a value already in flight from a cancelled one is dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var index: [UUID: TaskItem] = [:]
    /// Tasks looked up outside the lists, such as a restored session's finished task.
    @ObservationIgnored private var strays: [UUID: TaskItem] = [:]

    init(database: AppDatabase, clock: any TimeSource) {
        self.database = database
        self.clock = clock
        overview = TaskOverview(day: database.day(containing: clock.now))
        // Synchronous once, so the first popover frame already has its rows.
        reload()
        subscribe()
    }

    var today: CivilDay { overview.day }

    var tomorrow: CivilDay {
        let calendar = database.calendar
        let start = today.start(in: calendar)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return database.day(containing: next)
    }

    /// Open tasks first, each group in list order.
    var todayByStatus: [TaskItem] {
        overview.today.filter { !$0.isDone } + overview.today.filter(\.isDone)
    }

    func task(id: UUID?) -> TaskItem? {
        guard let id else { return nil }
        return index[id] ?? strays[id]
    }

    func actuals(for id: UUID) -> TaskActuals {
        overview.actuals(for: id)
    }

    /// Makes `task(id:)` find a task the lists don't show.
    func ensureLoaded(_ id: UUID?) {
        guard let id, task(id: id) == nil else { return }
        do {
            strays[id] = try database.tasks.fetch(id: id)
        } catch {
            Self.log.error("reading a task failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Day rollover

    /// "Today" is captured when a subscription starts, so a new day needs a new one.
    /// `force` re-subscribes even on the same day, for a time-zone change that moves its bounds.
    func rollOverIfNeeded(force: Bool = false) {
        guard force || database.day(containing: clock.now) != overview.day else { return }
        reload()
        subscribe()
    }

    func refreshSuggestion() {
        let id: UUID?
        do {
            id = try database.blocks.block(at: clock.now)?.taskID
        } catch {
            Self.log.error("reading the current block failed: \(String(describing: error), privacy: .public)")
            id = nil
        }
        ensureLoaded(id)
        if id != suggestedTaskID { suggestedTaskID = id }
    }

    // MARK: - Editing

    @discardableResult
    func add(_ entry: QuickAddResult, defaultDay: CivilDay?) -> TaskItem? {
        attempt("adding a task") {
            try database.tasks.create(entry, defaultDay: defaultDay, createdAt: clock.now)?.task
        } ?? nil
    }

    func setDone(_ id: UUID, _ isDone: Bool) {
        attempt("checking off a task") { try database.tasks.setDone(id: id, isDone, at: clock.now) }
    }

    func update(_ task: TaskItem) {
        guard task != self.task(id: task.id) else { return }
        attempt("saving a task") { try database.tasks.update(task) }
    }

    func schedule(_ id: UUID, on day: CivilDay?) {
        attempt("scheduling a task") { try database.tasks.schedule(id: id, on: day) }
    }

    func delete(_ id: UUID) {
        attempt("deleting a task") { try database.tasks.delete(id: id) }
    }

    /// Writes the new order of one list. The list is reordered here first, so a dragged row
    /// lands at once rather than when the observation catches up.
    func reorder(_ ids: [UUID]) {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        func moved(_ tasks: [TaskItem]) -> [TaskItem] {
            guard tasks.contains(where: { positions[$0.id] != nil }) else { return tasks }
            return tasks.sorted { (positions[$0.id] ?? .max, $0.sortIndex) < (positions[$1.id] ?? .max, $1.sortIndex) }
        }
        var optimistic = overview
        optimistic.today = moved(overview.today)
        optimistic.inbox = moved(overview.inbox)
        optimistic.upcoming = moved(overview.upcoming)
        apply(optimistic)
        attempt("reordering tasks") { try database.tasks.reorder(ids) }
    }

    // MARK: - Private

    private func reload() {
        attempt("reading tasks") { apply(try database.tasks.overview(now: clock.now)) }
    }

    private func subscribe() {
        generation += 1
        let generation = generation
        let stream = database.tasks.observeOverview(now: clock.now)
        observation.replace { [weak self] in
            for await value in stream {
                guard let self, self.generation == generation else { return }
                self.apply(value)
            }
        }
    }

    private func apply(_ value: TaskOverview) {
        // Observation notifies on every set; an unchanged list shouldn't re-render its rows.
        guard value != overview else { return }
        overview = value
        index = Dictionary((value.today + value.inbox + value.upcoming).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        strays = strays.filter { index[$0.key] == nil }
    }

    @discardableResult
    private func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            Self.log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Holds the observing task and cancels it with its owner, which a main-actor class can't do
/// from its own `deinit`.
private final class Subscription {
    private var task: Task<Void, Never>?

    @MainActor
    func replace(_ body: @escaping @MainActor @Sendable () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in await body() }
    }

    deinit {
        task?.cancel()
    }
}
