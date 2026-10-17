import Foundation
import PomodoroCore
@testable import Pomodoro

@MainActor
final class RecordingSoundPlayer: SoundPlayer {
    var volume: Float = 1
    private(set) var plays = 0

    func play() -> Bool {
        plays += 1
        return true
    }
}

/// Records every timer the model asks for and fires them only when time is advanced.
@MainActor
final class FakeScheduler: TimerScheduling {
    @MainActor
    final class Entry: ScheduledTimer {
        let date: Date
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false

        init(date: Date, action: @escaping @MainActor @Sendable () -> Void) {
            self.date = date
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    let clock: TestClock
    private var entries: [Entry] = []
    private(set) var firedCount = 0

    init(clock: TestClock) {
        self.clock = clock
    }

    var pendingDates: [Date] {
        entries.filter { !$0.isCancelled }.map(\.date).sorted()
    }

    func schedule(at date: Date, _ action: @escaping @MainActor @Sendable () -> Void) -> any ScheduledTimer {
        let entry = Entry(date: date, action: action)
        entries.append(entry)
        return entry
    }

    /// Moves the clock forward, firing due timers in order at their own dates.
    func advance(by interval: TimeInterval) {
        let target = clock.now + interval
        while let next = entries.filter({ !$0.isCancelled && $0.date <= target }).min(by: { $0.date < $1.date }) {
            next.isCancelled = true
            clock.now = max(clock.now, next.date)
            firedCount += 1
            next.action()
        }
        clock.now = target
        entries.removeAll { $0.isCancelled }
    }
}

/// Everything an `AppModel` needs, in memory and on a controllable clock.
@MainActor
final class ModelHarness {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Saturday 17 October 2026, 09:00 UTC.
    static let start = utc.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!

    let clock = TestClock(now: ModelHarness.start)
    let scheduler: FakeScheduler
    let settingsStore: InMemorySettingsStore
    let timerStore = InMemoryTimerStateStore()
    let database: AppDatabase
    let players: [SoundID: RecordingSoundPlayer]

    init(display: MenuBarDisplayMode = .time) throws {
        scheduler = FakeScheduler(clock: clock)
        var settings = AppSettings.default
        settings.menuBarDisplay = display
        settingsStore = InMemorySettingsStore(settings)
        database = try AppDatabase.inMemory(calendar: Self.utc)
        players = Dictionary(uniqueKeysWithValues: SoundID.allCases.filter { $0 != .none }.map { ($0, RecordingSoundPlayer()) })
    }

    func makeModel(onEngineUpdate: AppModel.EngineUpdate? = nil) -> AppModel {
        AppModel(
            clock: clock,
            settingsStore: settingsStore,
            timerStore: timerStore,
            database: database,
            sound: SoundService(players: players),
            scheduler: scheduler,
            onEngineUpdate: onEngineUpdate
        )
    }

    /// Edits the default (Classic) preset before a model loads the settings.
    func updateDefaultProfile(_ change: (inout TimerProfile) -> Void) {
        var settings = settingsStore.load()
        var preset = settings.defaultPreset
        change(&preset.profile)
        try? settings.updatePreset(preset)
        try? settingsStore.save(settings)
    }

    func plays(_ sound: SoundID) -> Int {
        players[sound]?.plays ?? 0
    }

    /// Logs completed pomodoros earlier today, an hour apart, ending before `start`.
    func seedCompletedSessions(_ count: Int) throws {
        for index in 0..<count {
            let begin = Self.start - TimeInterval(count - index) * 3600
            try database.sessions.insert(FocusSession(
                start: begin, end: begin + 1500, plannedSeconds: 1500, activeSeconds: 1500, completed: true
            ))
        }
    }

    struct SeededTasks {
        var writeSpec: TaskItem
        var reviewPR: TaskItem
        var all: [TaskItem]
    }

    /// A realistic day: six tasks today (one done, one over its estimate), two in the inbox, two
    /// upcoming on different days, sessions logged against some, and a block on "Review PR"
    /// running now.
    @discardableResult
    func seedTasks() throws -> SeededTasks {
        let today = database.day(containing: Self.start)
        let tomorrow = CivilDay(year: 2026, month: 10, day: 18)
        var created: [TaskItem] = []
        @discardableResult
        func add(_ title: String, _ estimate: Int?, tag: String? = nil, day: CivilDay?, notes: String = "") throws -> TaskItem {
            let task = try database.tasks.create(
                title: title, notes: notes, estimatePomodoros: estimate, tag: tag, scheduledDay: day, createdAt: Self.start - 7200)
            created.append(task)
            return task
        }
        let writeSpec = try add("Write spec for quick-add", 3, tag: "work", day: today, notes: "Cover the trailing-group rule")
        let reviewPR = try add("Review PR #42", 2, tag: "work", day: today)
        let inboxZero = try add("Inbox zero", 1, day: today)
        let standup = try add("Standup notes", nil, day: today)
        try add("Call the dentist", nil, day: today)
        try add("Read the design doc", 4, day: today)
        try add("Book flights", nil, day: nil)
        try add("Learn GRDB observation", 2, tag: "learning", day: nil)
        try add("Prepare demo", 2, day: tomorrow)
        try add("Quarterly review", 3, day: CivilDay(year: 2026, month: 10, day: 20))
        try database.tasks.setDone(id: standup.id, true, at: Self.start - 3600)

        // Hour-long slots from 03:00 so nothing overlaps the block or the seeded day total.
        var hour = 3.0
        for (task, count) in [(writeSpec, 2), (reviewPR, 3), (inboxZero, 0)] {
            for _ in 0..<count {
                let begin = Self.utc.startOfDay(for: Self.start) + hour * 3600
                try database.sessions.insert(FocusSession(
                    taskID: task.id, start: begin, end: begin + 1500, plannedSeconds: 1500, activeSeconds: 1500, completed: true
                ))
                hour += 1
            }
        }
        try database.blocks.insert(TimeBlock(taskID: reviewPR.id, title: reviewPR.title, start: Self.start - 900, duration: 3600))
        return SeededTasks(writeSpec: writeSpec, reviewPR: reviewPR, all: created)
    }

    static let longTitle = "Draft the quarterly planning document for the platform team, covering risks, staffing and milestones"

    /// A task whose title can't fit anywhere, estimated past the dot limit, beside an ordinary one.
    @discardableResult
    func seedLongTitle() throws -> TaskItem {
        let today = database.day(containing: Self.start)
        let long = try database.tasks.create(
            title: Self.longTitle, notes: "Long notes run on and on, past the edge of the sidebar row", estimatePomodoros: 8,
            tag: "planning", scheduledDay: today, createdAt: Self.start - 7200)
        try database.tasks.create(title: "Inbox zero", estimatePomodoros: 1, scheduledDay: today, createdAt: Self.start - 7200)
        return long
    }

    func sessionsToday() throws -> [FocusSession] {
        let day = Self.utc.startOfDay(for: Self.start)
        return try database.sessions.sessions(in: day..<(day + 86_400))
    }
}
