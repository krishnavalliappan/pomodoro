import Foundation
import Observation
import PomodoroCore
import os

/// The app's single source of truth: owns the engine and everything that reacts to it.
///
/// Nothing polls. One timer waits for `engine.nextBoundary`; a second, per-second one runs only
/// while someone can see the seconds (the popover is open, or the menu bar shows time).
@MainActor
@Observable
final class AppModel {
    enum EndPrompt: Equatable {
        case focusEnded
        case breakEnded
    }

    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "model")

    /// Lands a refresh just after the readout's digit flips, never on the stale side of it.
    static let refreshSlack: TimeInterval = 0.01

    private(set) var snapshot: TimerSnapshot
    /// Set while the end of a phase is waiting on the user: *Start break / +5 min / Keep going*.
    private(set) var prompt: EndPrompt? = nil
    private(set) var settings: AppSettings
    private(set) var planner = SessionPlanner()
    private(set) var completedToday = 0
    private(set) var isPopoverVisible = false
    /// Always `nil` until tasks land (#10).
    private(set) var currentTaskTitle: String? = nil

    /// Every batch of engine events, after the model has handled it. The seam for notifications.
    @ObservationIgnored var onEngineEvents: (([TimerEvent]) -> Void)?

    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored let sound: SoundService
    @ObservationIgnored private let engine: TimerEngine
    @ObservationIgnored private let clock: any TimeSource
    @ObservationIgnored private let settingsStore: any SettingsStore
    @ObservationIgnored private let timerStore: any TimerStateStore
    @ObservationIgnored private let scheduler: any TimerScheduling
    /// The profile the current focus (and the break right after it) runs on; the default
    /// profile unless a one-off override was consumed.
    @ObservationIgnored private var sessionProfile: TimerProfile
    @ObservationIgnored private var lastPersisted: PersistedTimer?
    @ObservationIgnored private var boundaryTimer: (any ScheduledTimer)?
    @ObservationIgnored private var refreshTimer: (any ScheduledTimer)?

    init(
        clock: any TimeSource = SystemClock(),
        settingsStore: any SettingsStore,
        timerStore: any TimerStateStore,
        database: AppDatabase,
        sound: SoundService,
        scheduler: any TimerScheduling
    ) {
        let settings = settingsStore.load()
        let restored = timerStore.load()
        let profile = restored.flatMap { $0.state.phase == .focus ? $0.profile : nil } ?? settings.defaultProfile
        let engine = TimerEngine(
            configuration: TimerConfiguration(profile: profile),
            clock: clock,
            state: restored?.state ?? TimerState()
        )
        self.clock = clock
        self.settingsStore = settingsStore
        self.timerStore = timerStore
        self.database = database
        self.sound = sound
        self.scheduler = scheduler
        self.engine = engine
        self.settings = settings
        self.sessionProfile = profile
        self.lastPersisted = restored
        self.snapshot = engine.snapshot()
        sound.settings = settings.sounds
        refreshCompletedToday()
        // A session restored from disk may have ended while the app wasn't running.
        reconcile()
    }

    static func live() -> AppModel {
        let database: AppDatabase
        do {
            database = try .onDisk()
        } catch {
            log.error("opening the database failed, sessions won't be saved: \(String(describing: error), privacy: .public)")
            // An in-memory queue only fails on programmer error.
            database = try! .inMemory()
        }
        return AppModel(
            settingsStore: UserDefaultsSettingsStore(),
            timerStore: UserDefaultsTimerStateStore(),
            database: database,
            sound: SoundService(),
            scheduler: RunLoopScheduler()
        )
    }

    // MARK: - Reading

    var statusTitle: String? {
        MenuBarTitle.text(for: snapshot, mode: settings.menuBarDisplay, taskTitle: currentTaskTitle)
    }

    var pendingOverride: SessionOverride? { planner.pendingOverride }

    /// What an idle readout shows: the next focus, including any pending override.
    var nextFocusDuration: TimeInterval {
        planner.previewProfile(base: settings.defaultProfile).focusDuration
    }

    var longBreakEvery: Int { settings.defaultProfile.longBreakEvery }

    var isRefreshingEverySecond: Bool { refreshTimer != nil }

    // MARK: - Timer actions

    func startFocus() {
        sessionProfile = planner.consumeProfile(base: settings.defaultProfile)
        engine.configuration = TimerConfiguration(profile: sessionProfile)
        handle(engine.start(phase: .focus))
    }

    /// Space: start when idle, otherwise pause or resume.
    func toggle() {
        guard engine.phase != .idle else { return startFocus() }
        switch engine.status {
        case .running, .overtime: pause()
        case .paused: resume()
        case .awaitingDecision: break
        }
    }

    func pause() { handle(engine.pause()) }
    func resume() { handle(engine.resume()) }
    func skip() { handle(engine.skip()) }
    func stop() { handle(engine.stopAndLog()) }
    func startBreak() { handle(engine.startBreak()) }
    func keepGoing() { handle(engine.keepGoing()) }

    func extend(minutes: Int) {
        handle(engine.extend(by: TimeInterval(minutes) * 60))
    }

    /// Catches up after the boundary timer fires, and after wake or a clock change.
    func reconcile() {
        handle(engine.reconcile())
    }

    // MARK: - Planning

    /// A preset chip makes that preset the default and drops any pending one-off override.
    func selectPreset(_ id: Preset.ID) {
        planner.clearOverride()
        updateSettings { try? $0.setDefaultPreset(id: id) }
    }

    /// Parses "40" or "50/10" as an override for the next focus only.
    @discardableResult
    func applyOverride(_ text: String) -> Bool {
        guard let override = SessionOverride(parsing: text) else { return false }
        planner.setOverride(override)
        return true
    }

    func clearOverride() {
        planner.clearOverride()
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        do {
            try settingsStore.save(updated)
        } catch {
            Self.log.error("saving settings failed: \(String(describing: error), privacy: .public)")
        }
        sound.settings = updated.sounds
        syncConfiguration()
        persistTimer()
        scheduleRefresh()
    }

    // MARK: - Visibility

    func setPopoverVisible(_ visible: Bool) {
        guard visible != isPopoverVisible else { return }
        isPopoverVisible = visible
        if visible {
            refreshSnapshot()
            refreshCompletedToday()
        }
        scheduleRefresh()
    }

    // MARK: - Event handling

    private func handle(_ events: [TimerEvent]) {
        for case .sessionRecorded(let record) in events {
            logSession(record)
        }
        if let event = Self.sound(for: events) {
            sound.play(for: event)
        }
        syncConfiguration()
        if engine.phase == .focus, engine.status == .running {
            sound.startTicking()
        } else {
            sound.stopTicking()
        }
        persistTimer()
        refreshSnapshot()
        scheduleBoundary()
        scheduleRefresh()
        if !events.isEmpty {
            onEngineEvents?(events)
        }
    }

    /// One sound per batch, so ending a phase and auto-starting the next doesn't double up.
    static func sound(for events: [TimerEvent]) -> SoundEvent? {
        if events.contains(.focusEnded) { return .focusEnd }
        if events.contains(.breakEnded) { return .breakEnd }
        if events.contains(where: { if case .phaseStarted = $0 { true } else { false } }) { return .start }
        return nil
    }

    private func logSession(_ record: FocusSessionRecord) {
        do {
            try database.sessions.insert(FocusSession(record: record))
        } catch {
            Self.log.error("logging a focus session failed: \(String(describing: error), privacy: .public)")
        }
        refreshCompletedToday()
    }

    /// The override lasts for one focus and the break begun from it; after that, the default.
    private func syncConfiguration() {
        if engine.phase != .focus {
            sessionProfile = settings.defaultProfile
        }
        let configuration = TimerConfiguration(profile: sessionProfile)
        if engine.configuration != configuration {
            engine.configuration = configuration
        }
    }

    private func persistTimer() {
        let persisted = PersistedTimer(state: engine.state, profile: sessionProfile)
        guard persisted != lastPersisted else { return }
        do {
            try timerStore.save(persisted)
            lastPersisted = persisted
        } catch {
            Self.log.error("saving timer state failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func refreshSnapshot() {
        let snapshot = engine.snapshot()
        self.snapshot = snapshot
        let waiting =
            switch snapshot.status {
            case .awaitingDecision: snapshot.phase != .idle
            case .overtime: !engine.state.nudgesSilenced
            case .running, .paused: false
            }
        prompt = waiting ? (snapshot.phase.isBreak ? .breakEnded : .focusEnded) : nil
    }

    private func refreshCompletedToday() {
        do {
            completedToday = try database.sessions.total(onDayContaining: clock.now).completedPomodoros
        } catch {
            Self.log.error("reading today's sessions failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Scheduling

    private func scheduleBoundary() {
        boundaryTimer?.cancel()
        boundaryTimer = nil
        guard let boundary = engine.nextBoundary else { return }
        boundaryTimer = scheduler.schedule(at: boundary) { [weak self] in
            self?.boundaryTimer = nil
            self?.reconcile()
        }
    }

    private var wantsSeconds: Bool {
        isPopoverVisible || settings.menuBarDisplay.showsSeconds
    }

    private func scheduleRefresh() {
        refreshTimer?.cancel()
        refreshTimer = nil
        guard wantsSeconds, let delay = TimerReadout.nextChange(after: snapshot) else { return }
        refreshTimer = scheduler.schedule(at: clock.now + delay + Self.refreshSlack) { [weak self] in
            self?.refreshTimer = nil
            self?.refreshSnapshot()
            self?.scheduleRefresh()
        }
    }
}
