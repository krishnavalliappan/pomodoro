import Foundation

/// Wall-clock anchored Pomodoro state machine.
///
/// Nothing ticks. Elapsed time is derived from `phaseStartedAt`, `pausedAccumulated` and the
/// clock, so the app only needs to call `reconcile()` at `nextBoundary`, after wake, and when the
/// system clock changes. Every action except `reset` reconciles first, so a stale engine never
/// acts on an outdated state.
///
/// If the clock goes backwards, stored dates shift back with it: accrued time is kept and an end
/// event that already fired never fires again.
///
/// Not thread-safe by design. A single owner (the app's main-actor model) makes every call, and
/// `onEvent` runs synchronously inside the call that produced the events.
public final class TimerEngine {
    /// An auto-started focus is skipped if the break ended longer ago than this, so a Mac
    /// waking from sleep doesn't start a focus nobody is there for. It measures lateness, so a
    /// reconcile delayed this long while awake skips it too.
    public static let autoStartFocusGrace: TimeInterval = 60

    /// Shorter durations, including zero and negative ones, are raised to this so every
    /// boundary is strictly later than the one before.
    public static let minimumPhaseDuration: TimeInterval = 1

    /// A backstop on auto-starts in one catch-up. Past it, the phase ends as if auto-start were off.
    public static let maxChainedAutoStarts = 8

    private static let epsilon: TimeInterval = 0.001

    /// Changing `nudgeInterval` during overtime keeps the last nudge as the anchor: the next one
    /// comes a new interval after it, or a new interval from now if that moment has passed.
    public var configuration: TimerConfiguration {
        didSet {
            if oldValue.nudgeInterval != configuration.nudgeInterval { reanchorNudges(at: clock.now) }
        }
    }
    public private(set) var state: TimerState
    /// Receives every event, in order. Actions also return them.
    public var onEvent: ((TimerEvent) -> Void)?

    private let clock: any TimeSource

    public init(
        configuration: TimerConfiguration = TimerConfiguration(),
        clock: any TimeSource = SystemClock(),
        state: TimerState = TimerState()
    ) {
        self.configuration = configuration
        self.clock = clock
        self.state = state
    }

    // MARK: - Reading

    public var phase: TimerPhase { state.phase }
    public var status: TimerStatus { state.status }
    public var taskID: UUID? { state.taskID }

    public func snapshot(at now: Date? = nil) -> TimerSnapshot {
        let now = now ?? clock.now
        let elapsed = state.phase == .idle ? 0 : state.elapsed(at: now)
        let planned = state.phase == .idle ? 0 : state.plannedDuration
        return TimerSnapshot(
            phase: state.phase,
            status: state.status,
            taskID: state.taskID,
            plannedDuration: planned,
            elapsed: elapsed,
            remaining: max(0, planned - elapsed),
            overtime: Self.clamped(elapsed - planned),
            completedFocusesInCycle: state.completedFocusesInCycle
        )
    }

    /// The next moment the engine needs `reconcile()`: the phase end, or the next nudge.
    /// `nil` means nothing will happen until the user acts.
    public var nextBoundary: Date? {
        guard state.phase != .idle, let end = state.phaseEndDate else { return nil }
        switch state.status {
        case .running:
            return end
        case .overtime:
            guard let interval = activeNudgeInterval else { return nil }
            return end + state.nudgeAnchor + interval
        case .paused, .awaitingDecision:
            return nil
        }
    }

    /// The break that would follow the current focus, counting it once it has reached its planned end.
    public var nextBreakPhase: TimerPhase {
        let interval = configuration.longBreakEvery
        let pending = state.phase == .focus && state.endDelivered ? 1 : 0
        return interval > 0 && state.completedFocusesInCycle + pending >= interval ? .longBreak : .shortBreak
    }

    // MARK: - Actions

    /// Starts a phase now, finishing (and recording) any focus in progress.
    /// `duration` is a one-off override; `nil` uses the configuration. See `minimumPhaseDuration`.
    @discardableResult
    public func start(phase: TimerPhase = .focus, duration: TimeInterval? = nil, taskID: UUID? = nil) -> [TimerEvent] {
        perform { now, events in
            finishFocusIfActive(at: now, events: &events)
            guard phase != .idle else {
                goIdle()
                return
            }
            if phase == .focus { state.taskID = taskID }
            begin(phase, at: now, duration: duration, events: &events)
        }
    }

    @discardableResult
    public func pause() -> [TimerEvent] {
        perform { now, _ in
            guard state.phase != .idle else { return }
            switch state.status {
            case .running, .overtime:
                state.pausedAt = now
                state.status = .paused
            case .paused, .awaitingDecision:
                break
            }
        }
    }

    @discardableResult
    public func resume() -> [TimerEvent] {
        perform { now, _ in
            guard state.phase != .idle, state.status == .paused else { return }
            unfreeze(at: now)
            // Only a delivered end means overtime; otherwise the boundary is still to fire.
            if state.endDelivered, let end = state.phaseEndDate {
                state.status = .overtime(since: end)
            } else {
                state.status = .running
            }
        }
    }

    /// Ends the current phase now and starts the next one.
    @discardableResult
    public func skip() -> [TimerEvent] {
        perform { now, events in
            switch state.phase {
            case .idle:
                break
            case .focus:
                finishFocusIfActive(at: now, events: &events)
                begin(nextBreakPhase, at: now, duration: nil, events: &events)
            case .shortBreak, .longBreak:
                begin(.focus, at: now, duration: nil, events: &events)
            }
        }
    }

    /// Discards the current phase without logging and clears the long-break cadence. It doesn't
    /// reconcile first, so an overdue boundary is discarded too: no record, end, or auto-start.
    @discardableResult
    public func reset() -> [TimerEvent] {
        state = TimerState()
        return []
    }

    /// Adds time. In overtime (or awaiting a decision) this means "`amount` more from now", so the
    /// overtime accrued so far becomes part of the plan and the end fires again.
    @discardableResult
    public func extend(by amount: TimeInterval) -> [TimerEvent] {
        perform { now, _ in
            guard state.phase != .idle, amount > 0 else { return }
            switch state.status {
            case .running, .paused:
                state.plannedDuration = max(state.plannedDuration, state.elapsed(at: now)) + amount
            case .overtime:
                state.plannedDuration = state.elapsed(at: now) + amount
                state.status = .running
            case .awaitingDecision:
                unfreeze(at: now)
                state.plannedDuration = state.elapsed(at: now) + amount
                state.status = .running
            }
            state.endDelivered = false
            state.nudgeAnchor = 0
            state.nudgesSilenced = false
        }
    }

    /// Logs the focus in progress (if any) and goes idle. On a break this is "Done for now".
    @discardableResult
    public func stopAndLog() -> [TimerEvent] {
        perform { now, events in
            guard state.phase != .idle else { return }
            finishFocusIfActive(at: now, events: &events)
            goIdle()
        }
    }

    /// Ends the focus (recording it) and starts the short or long break due next.
    @discardableResult
    public func startBreak() -> [TimerEvent] {
        perform { now, events in
            guard !state.phase.isBreak else { return }
            finishFocusIfActive(at: now, events: &events)
            begin(nextBreakPhase, at: now, duration: nil, events: &events)
        }
    }

    /// Dismisses the end-of-phase prompt: keep counting overtime, without further nudges.
    @discardableResult
    public func keepGoing() -> [TimerEvent] {
        perform { now, _ in
            guard state.phase != .idle else { return }
            switch state.status {
            case .overtime:
                state.nudgesSilenced = true
            case .awaitingDecision:
                unfreeze(at: now)
                state.status = .overtime(since: now)
                state.nudgeAnchor = 0
                state.nudgesSilenced = true
            case .running, .paused:
                break
            }
        }
    }

    /// Catches the state up to `now`: ends phases, auto-starts, and nudges. Call it at
    /// `nextBoundary` and after the system wakes.
    @discardableResult
    public func reconcile(now: Date) -> [TimerEvent] {
        var events: [TimerEvent] = []
        advance(to: now, events: &events)
        deliver(events)
        return events
    }

    @discardableResult
    public func reconcile() -> [TimerEvent] {
        reconcile(now: clock.now)
    }

    // MARK: - Internals

    private var activeNudgeInterval: TimeInterval? {
        guard !state.nudgesSilenced, let interval = configuration.nudgeInterval, interval > 0 else { return nil }
        return interval
    }

    private func perform(_ body: (Date, inout [TimerEvent]) -> Void) -> [TimerEvent] {
        let now = clock.now
        var events: [TimerEvent] = []
        advance(to: now, events: &events)
        body(now, &events)
        advance(to: now, events: &events)
        deliver(events)
        return events
    }

    private func deliver(_ events: [TimerEvent]) {
        guard let onEvent else { return }
        events.forEach(onEvent)
    }

    private func advance(to now: Date, events: inout [TimerEvent]) {
        observe(now)
        // Each pass ends at most one phase; auto-start can chain several across a long sleep.
        var autoStarts = 0
        while state.phase != .idle, let end = state.phaseEndDate {
            switch state.status {
            case .running:
                guard now >= end else { return }
                let allowAutoStart = autoStarts < Self.maxChainedAutoStarts
                phaseDidEnd(at: end, now: now, allowAutoStart: allowAutoStart, events: &events)
                if state.status == .running { autoStarts += 1 }
            case .overtime:
                nudgeIfDue(at: now, events: &events)
                return
            case .paused, .awaitingDecision:
                return
            }
        }
    }

    /// Shifts stored dates back when the clock has gone backwards, as though the jump never happened.
    private func observe(_ now: Date) {
        if let last = state.lastObservedAt, now < last {
            let shift = now.timeIntervalSince(last)
            state.phaseStartedAt = state.phaseStartedAt.map { $0 + shift }
            state.pausedAt = state.pausedAt.map { $0 + shift }
            if case .overtime(let since) = state.status { state.status = .overtime(since: since + shift) }
        }
        state.lastObservedAt = now
    }

    private func phaseDidEnd(at end: Date, now: Date, allowAutoStart: Bool, events: inout [TimerEvent]) {
        state.endDelivered = true
        if state.phase == .focus {
            events.append(.focusEnded)
            if allowAutoStart, configuration.autoStartBreaks {
                finishFocusIfActive(at: end, events: &events)
                begin(nextBreakPhase, at: end, duration: nil, events: &events)
                return
            }
        } else {
            events.append(.breakEnded)
            if allowAutoStart, configuration.autoStartFocus, now.timeIntervalSince(end) <= Self.autoStartFocusGrace {
                begin(.focus, at: end, duration: nil, events: &events)
                return
            }
        }

        if configuration.flowMode {
            state.status = .overtime(since: end)
            // Overtime that piled up while asleep is announced by the end event alone, not a burst of nudges.
            state.nudgeAnchor = activeNudgeInterval.map { (now.timeIntervalSince(end) / $0).rounded(.down) * $0 } ?? 0
        } else {
            state.status = .awaitingDecision
            state.pausedAt = end
        }
    }

    private func nudgeIfDue(at now: Date, events: inout [TimerEvent]) {
        guard let interval = activeNudgeInterval else { return }
        let overtime = currentOvertime(at: now)
        // Missed nudges coalesce into one, keeping the anchor on the interval grid.
        let due = ((overtime + Self.epsilon - state.nudgeAnchor) / interval).rounded(.down)
        guard due >= 1 else { return }
        state.nudgeAnchor += due * interval
        events.append(.nudge(overtime: overtime))
    }

    private func reanchorNudges(at now: Date) {
        observe(now)
        guard state.phase != .idle, state.endDelivered, let interval = activeNudgeInterval else { return }
        let overtime = currentOvertime(at: now)
        if state.nudgeAnchor + interval <= overtime { state.nudgeAnchor = overtime }
    }

    private func currentOvertime(at now: Date) -> TimeInterval {
        Self.clamped(state.elapsed(at: now) - state.plannedDuration)
    }

    private func begin(_ phase: TimerPhase, at date: Date, duration: TimeInterval?, events: inout [TimerEvent]) {
        if phase == .longBreak { state.completedFocusesInCycle = 0 }
        state.phase = phase
        state.status = .running
        state.phaseStartedAt = date
        state.plannedDuration = max(Self.minimumPhaseDuration, duration ?? configuration.duration(for: phase))
        state.pausedAccumulated = 0
        state.pausedAt = nil
        state.endDelivered = false
        state.nudgeAnchor = 0
        state.nudgesSilenced = false
        events.append(.phaseStarted(phase))
    }

    private func goIdle() {
        var idle = TimerState()
        idle.completedFocusesInCycle = state.completedFocusesInCycle
        state = idle
    }

    private func unfreeze(at now: Date) {
        guard let pausedAt = state.pausedAt else { return }
        state.pausedAccumulated += max(0, now.timeIntervalSince(pausedAt))
        state.pausedAt = nil
    }

    private func finishFocusIfActive(at now: Date, events: inout [TimerEvent]) {
        guard state.phase == .focus, let startedAt = state.phaseStartedAt else { return }
        let active = state.elapsed(at: now)
        let completed = state.endDelivered || active + Self.epsilon >= state.plannedDuration
        if completed { state.completedFocusesInCycle += 1 }
        let record = FocusSessionRecord(
            taskID: state.taskID,
            startedAt: startedAt,
            endedAt: state.pausedAt ?? now,
            plannedDuration: state.plannedDuration,
            activeDuration: active,
            pausedDuration: state.pausedAccumulated,
            overtime: Self.clamped(active - state.plannedDuration),
            outcome: completed ? .completed : .abandoned
        )
        events.append(.sessionRecorded(record))
        // Leave the phase so a second call (e.g. from begin's caller) can't log it twice.
        state.phase = .idle
    }

    private static func clamped(_ value: TimeInterval) -> TimeInterval {
        value > epsilon ? value : 0
    }
}
