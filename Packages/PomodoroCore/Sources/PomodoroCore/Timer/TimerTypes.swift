import Foundation

public enum TimerPhase: String, Sendable, Codable, CaseIterable {
    case idle
    case focus
    case shortBreak
    case longBreak

    public var isBreak: Bool { self == .shortBreak || self == .longBreak }
}

public enum TimerStatus: Sendable, Equatable, Codable {
    case running
    case paused
    /// The phase reached zero at `since` (shifted by any pauses) and is counting up.
    case overtime(since: Date)
    /// The phase reached zero with flow mode off, so time is frozen until the user decides.
    /// Also the status of `.idle`, which is waiting for the user to start something.
    case awaitingDecision
}

public enum TimerEvent: Sendable, Equatable {
    case phaseStarted(TimerPhase)
    case focusEnded
    case breakEnded
    case nudge(overtime: TimeInterval)
    case sessionRecorded(FocusSessionRecord)
}

public enum FocusSessionOutcome: String, Sendable, Codable {
    /// The focus ran for at least its planned duration.
    case completed
    /// It was skipped or stopped early. The active time still counts toward the task.
    case abandoned
}

public struct FocusSessionRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var taskID: UUID?
    public var startedAt: Date
    /// When work stopped. Equals `startedAt + activeDuration + pausedDuration`.
    public var endedAt: Date
    /// Planned length including any extensions.
    public var plannedDuration: TimeInterval
    /// Focused time, excluding pauses and including overtime.
    public var activeDuration: TimeInterval
    public var pausedDuration: TimeInterval
    public var overtime: TimeInterval
    public var outcome: FocusSessionOutcome

    public init(
        id: UUID = UUID(),
        taskID: UUID?,
        startedAt: Date,
        endedAt: Date,
        plannedDuration: TimeInterval,
        activeDuration: TimeInterval,
        pausedDuration: TimeInterval,
        overtime: TimeInterval,
        outcome: FocusSessionOutcome
    ) {
        self.id = id
        self.taskID = taskID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedDuration = plannedDuration
        self.activeDuration = activeDuration
        self.pausedDuration = pausedDuration
        self.overtime = overtime
        self.outcome = outcome
    }
}

/// Everything the engine stores. Codable so the app can persist it across relaunches.
public struct TimerState: Sendable, Equatable, Codable {
    public var phase: TimerPhase = .idle
    public var status: TimerStatus = .awaitingDecision
    public var phaseStartedAt: Date?
    public var plannedDuration: TimeInterval = 0
    public var pausedAccumulated: TimeInterval = 0
    /// Set while paused, and while awaiting a decision (frozen at the phase end).
    public var pausedAt: Date?
    public var taskID: UUID?
    public var completedFocusesInCycle = 0
    /// The current plan's end event has fired. Cleared when a phase begins or is extended.
    public var endDelivered = false
    /// Overtime (seconds past the phase end) that the next nudge counts from: the last nudge, or 0.
    public var nudgeAnchor: TimeInterval = 0
    public var nudgesSilenced = false
    /// The latest time the engine has seen, used to detect the clock going backwards.
    public var lastObservedAt: Date?

    public init() {}

    public func elapsed(at now: Date) -> TimeInterval {
        guard let phaseStartedAt else { return 0 }
        return max(0, (pausedAt ?? now).timeIntervalSince(phaseStartedAt) - pausedAccumulated)
    }

    /// When the planned duration runs out, assuming no further pauses.
    public var phaseEndDate: Date? {
        phaseStartedAt.map { $0 + pausedAccumulated + plannedDuration }
    }
}

/// A point-in-time read of the engine for the UI.
public struct TimerSnapshot: Sendable, Equatable {
    public var phase: TimerPhase
    public var status: TimerStatus
    public var taskID: UUID?
    public var plannedDuration: TimeInterval
    public var elapsed: TimeInterval
    public var remaining: TimeInterval
    public var overtime: TimeInterval
    public var completedFocusesInCycle: Int

    public var isOvertime: Bool { overtime > 0 }
    public var progress: Double {
        plannedDuration > 0 ? min(1, elapsed / plannedDuration) : 0
    }
}
