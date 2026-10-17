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

    func sessionsToday() throws -> [FocusSession] {
        let day = Self.utc.startOfDay(for: Self.start)
        return try database.sessions.sessions(in: day..<(day + 86_400))
    }
}
