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

    /// Parses typed chip input in minutes: "40" or "50/10". Values beyond `Int` are rejected.
    public init?(parsing text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count) else { return nil }
        let minutes = parts.map { Int($0) }
        guard minutes.allSatisfy({ $0 != nil && $0! > 0 }) else { return nil }
        // Multiplying as Double so huge input clamps instead of overflowing Int.
        self.init(
            focus: TimeInterval(minutes[0]!) * 60,
            break: minutes.count == 2 ? TimeInterval(minutes[1]!) * 60 : nil
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

/// A one-off choice for the next focus and the break after it: a preset picked from the chips,
/// or typed durations layered on the default profile.
public enum SessionOneOff: Hashable, Sendable {
    case preset(Preset.ID)
    case custom(SessionOverride)

    /// `nil` when the preset has since been deleted, so the default applies.
    public func profile(in settings: AppSettings) -> TimerProfile? {
        switch self {
        case .preset(let id): settings.preset(id: id)?.profile
        case .custom(let override): override.applied(to: settings.defaultProfile)
        }
    }
}

/// Holds a pending one-off until the next focus begins. It is kept apart from `AppSettings` on
/// purpose, so a one-off can never leak into persisted defaults.
public struct SessionPlanner: Hashable, Sendable {
    public private(set) var pending: SessionOneOff?

    public init(pending: SessionOneOff? = nil) {
        set(pending)
    }

    public init(pendingOverride: SessionOverride?) {
        self.init(pending: pendingOverride.map(SessionOneOff.custom))
    }

    public var pendingOverride: SessionOverride? {
        if case .custom(let override) = pending { override } else { nil }
    }

    public var pendingPresetID: Preset.ID? {
        if case .preset(let id) = pending { id } else { nil }
    }

    public mutating func set(_ oneOff: SessionOneOff?) {
        if case .custom(let override) = oneOff, override.isEmpty {
            pending = nil
        } else {
            pending = oneOff
        }
    }

    public mutating func setOverride(_ override: SessionOverride?) {
        set(override.map(SessionOneOff.custom))
    }

    public mutating func clear() {
        pending = nil
    }

    /// What the next focus would use, without consuming the one-off.
    public func previewProfile(in settings: AppSettings) -> TimerProfile {
        pending?.profile(in: settings) ?? settings.defaultProfile
    }

    /// The one-off profile for the focus beginning now (and its break), or `nil` for the default.
    /// Either way nothing is pending afterwards, so the focus after this one is back on defaults.
    public mutating func consumeProfile(in settings: AppSettings) -> TimerProfile? {
        defer { pending = nil }
        return pending?.profile(in: settings)
    }
}
