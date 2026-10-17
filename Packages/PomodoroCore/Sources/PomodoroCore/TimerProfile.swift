import Foundation

/// Durations and behaviour for a run of pomodoros. Field-for-field this mirrors the timer engine's
/// configuration, so the app can bridge one to the other without extra rules.
public struct TimerProfile: Hashable, Sendable {
    public static let durationRange: ClosedRange<TimeInterval> = 60...(180 * 60)
    public static let longBreakEveryRange: ClosedRange<Int> = 1...16

    public var focusDuration: TimeInterval {
        didSet { focusDuration = Self.clampDuration(focusDuration) }
    }
    public var shortBreakDuration: TimeInterval {
        didSet { shortBreakDuration = Self.clampDuration(shortBreakDuration) }
    }
    public var longBreakDuration: TimeInterval {
        didSet { longBreakDuration = Self.clampDuration(longBreakDuration) }
    }
    public var longBreakEvery: Int {
        didSet { longBreakEvery = Self.clampLongBreakEvery(longBreakEvery) }
    }
    public var autoStartBreaks: Bool
    public var autoStartFocus: Bool
    public var flowMode: Bool
    /// `nil` turns overtime re-nudges off.
    public var nudgeInterval: TimeInterval? {
        didSet { nudgeInterval = nudgeInterval.map(Self.clampDuration) }
    }

    public init(
        focusDuration: TimeInterval,
        shortBreakDuration: TimeInterval,
        longBreakDuration: TimeInterval,
        longBreakEvery: Int = 4,
        autoStartBreaks: Bool = false,
        autoStartFocus: Bool = false,
        flowMode: Bool = true,
        nudgeInterval: TimeInterval? = TimerProfile.defaultNudgeInterval
    ) {
        self.focusDuration = Self.clampDuration(focusDuration)
        self.shortBreakDuration = Self.clampDuration(shortBreakDuration)
        self.longBreakDuration = Self.clampDuration(longBreakDuration)
        self.longBreakEvery = Self.clampLongBreakEvery(longBreakEvery)
        self.autoStartBreaks = autoStartBreaks
        self.autoStartFocus = autoStartFocus
        self.flowMode = flowMode
        self.nudgeInterval = nudgeInterval.map(Self.clampDuration)
    }

    public static let defaultNudgeInterval: TimeInterval = 10 * 60

    public static let classic = TimerProfile(focusDuration: 25 * 60, shortBreakDuration: 5 * 60, longBreakDuration: 15 * 60)
    public static let deep = TimerProfile(focusDuration: 50 * 60, shortBreakDuration: 10 * 60, longBreakDuration: 20 * 60)
    public static let quick = TimerProfile(focusDuration: 15 * 60, shortBreakDuration: 3 * 60, longBreakDuration: 10 * 60)

    /// "25/5/15", in whole minutes.
    public var summary: String {
        [focusDuration, shortBreakDuration, longBreakDuration]
            .map { String(Int(($0 / 60).rounded())) }
            .joined(separator: "/")
    }

    public static func clampDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return durationRange.lowerBound }
        return min(max(value, durationRange.lowerBound), durationRange.upperBound)
    }

    public static func clampLongBreakEvery(_ value: Int) -> Int {
        min(max(value, longBreakEveryRange.lowerBound), longBreakEveryRange.upperBound)
    }
}

extension TimerProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusDuration, shortBreakDuration, longBreakDuration, longBreakEvery
        case autoStartBreaks, autoStartFocus, flowMode, nudgeInterval
    }

    /// Missing or malformed fields fall back to Classic, so older or hand-edited data still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = TimerProfile.classic
        let nudge: TimeInterval?
        if !c.contains(.nudgeInterval) {
            nudge = base.nudgeInterval
        } else if (try? c.decodeNil(forKey: .nudgeInterval)) == true {
            nudge = nil
        } else {
            nudge = c.lenient(TimeInterval.self, .nudgeInterval) ?? base.nudgeInterval
        }
        self.init(
            focusDuration: c.lenient(TimeInterval.self, .focusDuration) ?? base.focusDuration,
            shortBreakDuration: c.lenient(TimeInterval.self, .shortBreakDuration) ?? base.shortBreakDuration,
            longBreakDuration: c.lenient(TimeInterval.self, .longBreakDuration) ?? base.longBreakDuration,
            longBreakEvery: c.lenient(Int.self, .longBreakEvery) ?? base.longBreakEvery,
            autoStartBreaks: c.lenient(Bool.self, .autoStartBreaks) ?? base.autoStartBreaks,
            autoStartFocus: c.lenient(Bool.self, .autoStartFocus) ?? base.autoStartFocus,
            flowMode: c.lenient(Bool.self, .flowMode) ?? base.flowMode,
            nudgeInterval: nudge
        )
    }

    // Written explicitly so a disabled nudge encodes as null rather than vanishing, which
    // would read back as "missing" and silently re-enable the default.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(focusDuration, forKey: .focusDuration)
        try c.encode(shortBreakDuration, forKey: .shortBreakDuration)
        try c.encode(longBreakDuration, forKey: .longBreakDuration)
        try c.encode(longBreakEvery, forKey: .longBreakEvery)
        try c.encode(autoStartBreaks, forKey: .autoStartBreaks)
        try c.encode(autoStartFocus, forKey: .autoStartFocus)
        try c.encode(flowMode, forKey: .flowMode)
        try c.encode(nudgeInterval, forKey: .nudgeInterval)
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}
