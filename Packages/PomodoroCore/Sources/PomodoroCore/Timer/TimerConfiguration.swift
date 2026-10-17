import Foundation

/// The durations and behaviour flags the engine needs. Profiles and presets map onto this.
/// Durations below `TimerEngine.minimumPhaseDuration` (including zero or negative) are raised
/// to it when a phase begins, rather than rejected.
public struct TimerConfiguration: Sendable, Equatable, Codable {
    public var focusDuration: TimeInterval
    public var shortBreakDuration: TimeInterval
    public var longBreakDuration: TimeInterval
    /// A long break follows every N completed focus sessions. Zero or less disables long breaks,
    /// which profiles never produce (they allow 1...16) but the engine supports.
    public var longBreakEvery: Int
    /// Flow mode: when a phase ends, keep counting overtime instead of stopping.
    public var flowMode: Bool
    /// How often to re-nudge while in overtime. `nil` (or non-positive) turns nudges off.
    public var nudgeInterval: TimeInterval?
    public var autoStartBreaks: Bool
    public var autoStartFocus: Bool

    public init(
        focusDuration: TimeInterval = 25 * 60,
        shortBreakDuration: TimeInterval = 5 * 60,
        longBreakDuration: TimeInterval = 15 * 60,
        longBreakEvery: Int = 4,
        flowMode: Bool = true,
        nudgeInterval: TimeInterval? = 10 * 60,
        autoStartBreaks: Bool = false,
        autoStartFocus: Bool = false
    ) {
        self.focusDuration = focusDuration
        self.shortBreakDuration = shortBreakDuration
        self.longBreakDuration = longBreakDuration
        self.longBreakEvery = longBreakEvery
        self.flowMode = flowMode
        self.nudgeInterval = nudgeInterval
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
    }

    public func duration(for phase: TimerPhase) -> TimeInterval {
        switch phase {
        case .idle: 0
        case .focus: focusDuration
        case .shortBreak: shortBreakDuration
        case .longBreak: longBreakDuration
        }
    }
}
