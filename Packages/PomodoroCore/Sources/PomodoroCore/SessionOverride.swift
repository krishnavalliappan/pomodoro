import Foundation

/// A duration change for the next session only, e.g. "this one is 50/10".
public struct SessionOverride: Hashable, Sendable {
    public var focus: TimeInterval?
    /// Replaces whichever break follows, short or long.
    public var breakDuration: TimeInterval?

    public init(focus: TimeInterval? = nil, break breakDuration: TimeInterval? = nil) {
        self.focus = focus.map(TimerProfile.clampDuration)
        self.breakDuration = breakDuration.map(TimerProfile.clampDuration)
    }

    /// Parses typed chip input in minutes: "40" or "50/10".
    public init?(parsing text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return nil }
        let minutes = parts.map { Int($0) }
        guard minutes.allSatisfy({ $0 != nil && $0! > 0 }) else { return nil }
        self.init(
            focus: TimeInterval(minutes[0]! * 60),
            break: minutes.count == 2 ? TimeInterval(minutes[1]! * 60) : nil
        )
    }

    public var isEmpty: Bool { focus == nil && breakDuration == nil }

    public func applied(to profile: TimerProfile) -> TimerProfile {
        var result = profile
        if let focus { result.focusDuration = focus }
        if let breakDuration {
            result.shortBreakDuration = breakDuration
            result.longBreakDuration = breakDuration
        }
        return result
    }
}

/// Holds a pending one-off override until the next session starts. It is kept apart from
/// `AppSettings` on purpose, so an override can never leak into persisted defaults.
public struct SessionPlanner: Hashable, Sendable {
    public private(set) var pendingOverride: SessionOverride?

    public init(pendingOverride: SessionOverride? = nil) {
        setOverride(pendingOverride)
    }

    public mutating func setOverride(_ override: SessionOverride?) {
        pendingOverride = override?.isEmpty == true ? nil : override
    }

    public mutating func clearOverride() {
        pendingOverride = nil
    }

    /// What the next session would use, without consuming the override.
    public func previewProfile(base: TimerProfile) -> TimerProfile {
        pendingOverride?.applied(to: base) ?? base
    }

    /// The profile for the session that is starting now. The override is used up.
    public mutating func consumeProfile(base: TimerProfile) -> TimerProfile {
        defer { pendingOverride = nil }
        return previewProfile(base: base)
    }
}
