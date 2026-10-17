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
    /// `snapshot.phase`, for views that must not re-render every second.
    private(set) var phase: TimerPhase
    /// Set while the end of a phase is waiting on the user: *Start break / +5 min / Keep going*.
    private(set) var prompt: EndPrompt? = nil
    private(set) var settings: AppSettings
    /// The last settings save that failed, e.g. a newer build owns the stored data. Edits still
    /// apply for this run; Settings shows this so they aren't silently lost on quit.
    private(set) var settingsSaveError: SettingsStoreError? = nil
    private(set) var planner = SessionPlanner()
    private(set) var completedToday = 0
    private(set) var isPopoverVisible = false
    /// Set by the quick-add hotkey until the popover's field takes focus.
    private(set) var wantsQuickAddFocus = false
    /// The task the current focus counts toward, or the next one will. It outlives a stop, so
    /// the next start picks it up again.
    private(set) var selectedTaskID: UUID? = nil
    /// Its own observable, so task edits don't re-render the timer.
    let tasks: TaskStore

    typealias EngineUpdate = @MainActor (TimerEngine, [TimerEvent]) -> Void

    /// Called synchronously after every engine call the model makes, once it has logged, played
    /// sounds, persisted and rescheduled: each action (including those that return no events),
    /// each reconcile (including the one at launch), and each settings change that reaches the
    /// engine. The seam for #9: `notifications.sync(with:events:)` and `appNap.update(with:)`.
    /// Pass it to `init` to see the launch reconcile.
    @ObservationIgnored var onEngineUpdate: EngineUpdate?

    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored let sound: SoundService
    @ObservationIgnored private let engine: TimerEngine
    @ObservationIgnored let clock: any TimeSource
    @ObservationIgnored private let settingsStore: any SettingsStore
    @ObservationIgnored private let timerStore: any TimerStateStore
    @ObservationIgnored private let scheduler: any TimerScheduling
    /// The one-off the current focus and the break after it run on; `nil` follows the default.
    @ObservationIgnored private var oneOffProfile: TimerProfile?
    @ObservationIgnored private var lastPersisted: PersistedTimer?
    @ObservationIgnored private var boundaryTimer: (any ScheduledTimer)?
    @ObservationIgnored private var refreshTimer: (any ScheduledTimer)?
    @ObservationIgnored private var dayMonitor: DayChangeMonitor?

    init(
        clock: any TimeSource = SystemClock(),
        settingsStore: any SettingsStore,
        timerStore: any TimerStateStore,
        database: AppDatabase,
        sound: SoundService,
        scheduler: any TimerScheduling,
        onEngineUpdate: EngineUpdate? = nil
    ) {
        let settings = settingsStore.load()
        let restored = timerStore.load()
        let oneOff = restored?.state.phase == .idle ? nil : restored?.profile
        let engine = TimerEngine(
            configuration: TimerConfiguration(profile: oneOff ?? settings.defaultProfile),
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
        self.oneOffProfile = oneOff
        self.lastPersisted = restored
        self.onEngineUpdate = onEngineUpdate
        self.snapshot = engine.snapshot()
        self.phase = engine.phase
        self.tasks = TaskStore(database: database, clock: clock)
        self.selectedTaskID = engine.taskID
        tasks.ensureLoaded(engine.taskID)
        sound.settings = settings.sounds
        // Every focus picks its profile here, including one auto-started inside a catch-up.
        engine.configurationForFocus = { [weak self] in self?.configurationForFocus() }
        refreshCompletedToday()
        // A session restored from disk may have ended while the app wasn't running.
        reconcile()
    }

    static func live(onEngineUpdate: EngineUpdate? = nil) -> AppModel {
        let database: AppDatabase
        do {
            database = try .onDisk()
        } catch {
            log.error("opening the database failed, sessions won't be saved: \(String(describing: error), privacy: .public)")
            // An in-memory queue only fails on programmer error.
            database = try! .inMemory()
        }
        let model = AppModel(
            settingsStore: UserDefaultsSettingsStore(),
            timerStore: UserDefaultsTimerStateStore(),
            database: database,
            sound: SoundService(),
            scheduler: RunLoopScheduler(),
            onEngineUpdate: onEngineUpdate
        )
        model.observeDayChanges()
        return model
    }

    // MARK: - Reading

    var statusTitle: String? {
        MenuBarTitle.text(for: snapshot, mode: settings.menuBarDisplay, taskTitle: currentTaskTitle)
    }

    var currentTaskTitle: String? {
        tasks.task(id: selectedTaskID)?.title
    }

    /// A focus is under way, so picking a task re-attributes it rather than starting one.
    var isFocusing: Bool { phase == .focus }

    var pendingOneOff: SessionOneOff? { planner.pending }
    var pendingOverride: SessionOverride? { planner.pendingOverride }

    /// What an idle readout shows: the next focus, including any pending one-off.
    var nextFocusDuration: TimeInterval {
        planner.previewProfile(in: settings).focusDuration
    }

    var longBreakEvery: Int { settings.defaultProfile.longBreakEvery }

    var isRefreshingEverySecond: Bool { refreshTimer != nil }

    // MARK: - Timer actions

    func startFocus() { handle(engine.start(phase: .focus, taskID: selectedTaskID)) }

    /// ▶ on a task: during a focus it switches the running session to the task, otherwise it
    /// starts a focus on it.
    func startFocus(on taskID: UUID) {
        if isFocusing {
            selectTask(taskID)
        } else {
            setSelectedTask(taskID)
            startFocus()
        }
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
    func stopAndLog() { handle(engine.stopAndLog()) }
    func startBreak() { handle(engine.startBreak()) }
    func keepGoing() { handle(engine.keepGoing()) }
    func extend(by amount: TimeInterval) { handle(engine.extend(by: amount)) }

    func extend(minutes: Int) {
        extend(by: TimeInterval(minutes) * 60)
    }

    /// Catches up after the boundary timer fires, and after wake or a clock change.
    func reconcile() {
        handle(engine.reconcile())
    }

    // MARK: - Tasks

    /// Picks the current task. Mid-phase the running session is re-attributed, so its whole
    /// time counts toward the new task.
    func selectTask(_ taskID: UUID?) {
        setSelectedTask(taskID)
        guard engine.phase != .idle, engine.taskID != taskID else { return }
        handle(engine.assignTask(taskID))
    }

    func quickAddParser() -> QuickAddParser {
        QuickAddParser(calendar: database.calendar, pomodoroLength: settings.defaultProfile.focusDuration)
    }

    func parseQuickAdd(_ text: String) -> QuickAddResult {
        quickAddParser().parse(text, now: clock.now)
    }

    /// Adds a task from a quick-add line, plus a block if it names a start time. A line that
    /// names no day goes to today, or the inbox. Blank titles add nothing.
    @discardableResult
    func addTask(_ text: String, toInbox: Bool = false) -> TaskItem? {
        tasks.add(parseQuickAdd(text), defaultDay: toInbox ? nil : tasks.today)
    }

    func requestQuickAddFocus() {
        wantsQuickAddFocus = true
    }

    func quickAddFocusTaken() {
        if wantsQuickAddFocus { wantsQuickAddFocus = false }
    }

    func deleteTask(_ id: UUID) {
        // Sessions can't reference a deleted task, so the running one lets go of it first.
        if selectedTaskID == id { selectTask(nil) }
        tasks.delete(id)
    }

    // MARK: - Day rollover

    func observeDayChanges(
        center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = DayChangeMonitor.workspaceCenter
    ) {
        dayMonitor?.stop()
        dayMonitor = DayChangeMonitor(center: center, workspaceCenter: workspaceCenter) { [weak self] reason in
            self?.dayMayHaveChanged(reason)
        }
    }

    func dayMayHaveChanged(_ reason: DayChangeMonitor.Reason) {
        tasks.rollOverIfNeeded(force: reason == .timeZoneChanged)
        refreshCompletedToday()
        if isPopoverVisible { tasks.refreshSuggestion() }
    }

    // MARK: - Planning

    /// A chip picks a preset for the next focus and its break only, never the default. Tapping
    /// it again, or tapping the default's chip, goes back to the default.
    func toggleOneOffPreset(_ id: Preset.ID) {
        if planner.pendingPresetID == id || id == settings.defaultPresetID {
            planner.clear()
        } else {
            planner.set(.preset(id))
        }
    }

    /// Parses "40" or "50/10" as a one-off for the next focus and its break.
    @discardableResult
    func applyOverride(_ text: String) -> Bool {
        guard let override = SessionOverride(parsing: text) else { return false }
        planner.setOverride(override)
        return true
    }

    func clearOneOff() {
        planner.clear()
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        do {
            try settingsStore.save(updated)
            if settingsSaveError != nil { settingsSaveError = nil }
        } catch {
            Self.log.error("saving settings failed: \(String(describing: error), privacy: .public)")
            if let error = error as? SettingsStoreError, error != settingsSaveError { settingsSaveError = error }
        }
        sound.settings = updated.sounds
        // A new nudge interval or auto-start moves the boundary, so this takes the same path as an action.
        handle([])
    }

    func dismissSettingsSaveError() {
        settingsSaveError = nil
    }

    /// Cancels pending timers and the tick. The run loop would otherwise keep a one-shot timer
    /// alive after the model is gone.
    func shutdown() {
        dayMonitor?.stop()
        dayMonitor = nil
        boundaryTimer?.cancel()
        boundaryTimer = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        sound.stopTicking()
    }

    // MARK: - Visibility

    func setPopoverVisible(_ visible: Bool) {
        guard visible != isPopoverVisible else { return }
        isPopoverVisible = visible
        // A request the field never took mustn't steal focus on the next plain open.
        if !visible { quickAddFocusTaken() }
        if visible {
            refreshSnapshot()
            refreshCompletedToday()
            tasks.refreshSuggestion()
        }
        scheduleRefresh()
    }

    // MARK: - Event handling

    private func handle(_ events: [TimerEvent]) {
        for case .sessionRecorded(let record) in events {
            logSession(record)
        }
        if let event = Self.sound(for: events, phase: engine.phase) {
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
        onEngineUpdate?(engine, events)
    }

    /// One sound per batch, so ending a phase and auto-starting the next doesn't double up.
    /// Notifications stay silent (#9), so an overtime nudge repeats the phase's end chime here.
    static func sound(for events: [TimerEvent], phase: TimerPhase) -> SoundEvent? {
        if events.contains(.focusEnded) { return .focusEnd }
        if events.contains(.breakEnded) { return .breakEnd }
        if events.contains(where: { if case .phaseStarted = $0 { true } else { false } }) { return .start }
        if events.contains(where: { if case .nudge = $0 { true } else { false } }) {
            return phase.isBreak ? .breakEnd : .focusEnd
        }
        return nil
    }

    private func logSession(_ record: FocusSessionRecord) {
        do {
            try database.sessions.insert(FocusSession(record: record))
        } catch where record.taskID != nil {
            // The task is gone (deleted elsewhere); keep the time, unlinked, as a deletion would.
            Self.log.error("logging a focus session failed, retrying without its task: \(String(describing: error), privacy: .public)")
            var unlinked = record
            unlinked.taskID = nil
            try? database.sessions.insert(FocusSession(record: unlinked))
        } catch {
            Self.log.error("logging a focus session failed: \(String(describing: error), privacy: .public)")
        }
        refreshCompletedToday()
    }

    private func setSelectedTask(_ taskID: UUID?) {
        tasks.ensureLoaded(taskID)
        if taskID != selectedTaskID { selectedTaskID = taskID }
    }

    /// Consumes the pending one-off as a focus begins. It stays in force through the break that
    /// follows, and the next focus to begin consumes again, so it can't reach a later focus.
    private func configurationForFocus() -> TimerConfiguration {
        oneOffProfile = planner.consumeProfile(in: settings)
        return TimerConfiguration(profile: oneOffProfile ?? settings.defaultProfile)
    }

    /// Keeps the engine on the session's profile, so settings changes reach default sessions.
    private func syncConfiguration() {
        if engine.phase == .idle { oneOffProfile = nil }
        let configuration = TimerConfiguration(profile: oneOffProfile ?? settings.defaultProfile)
        if engine.configuration != configuration {
            engine.configuration = configuration
        }
    }

    private func persistTimer() {
        let persisted = PersistedTimer(state: engine.state, profile: oneOffProfile)
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
        if snapshot.phase != phase { phase = snapshot.phase }
        let waiting =
            switch snapshot.status {
            case .awaitingDecision: snapshot.phase != .idle
            case .overtime: !engine.state.nudgesSilenced
            case .running, .paused: false
            }
        let prompt: EndPrompt? = waiting ? (snapshot.phase.isBreak ? .breakEnded : .focusEnded) : nil
        // Observation notifies on every set, so leave an unchanged prompt alone.
        if prompt != self.prompt { self.prompt = prompt }
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
