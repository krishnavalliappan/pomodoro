import Foundation

public enum AmbientBreakBehavior: String, Codable, CaseIterable, Sendable {
    /// Fade out for the break and back in when focus resumes.
    case off
    /// Keep playing, at `AmbientPolicy.loweredLevel`.
    case lower
    /// Keep playing as is.
    case keep
}

/// When the ambient mix plays. Focus plays it; pausing, stopping or a frozen phase end silences
/// it; breaks follow `duringBreaks`.
public struct AmbientPolicy: Hashable, Sendable {
    public static let loweredLevel = 0.35

    public var duringBreaks: AmbientBreakBehavior

    public init(duringBreaks: AmbientBreakBehavior = .off) {
        self.duringBreaks = duringBreaks
    }

    /// How loud the mix plays, 0…1, in this state of the timer.
    ///
    /// Focus overtime still plays: flow mode means the user is still focusing. A phase frozen at
    /// its end (`awaitingDecision`) is silent, as the time is.
    public func level(phase: TimerPhase, status: TimerStatus) -> Double {
        switch status {
        case .paused, .awaitingDecision:
            return 0
        case .running, .overtime:
            break
        }
        switch phase {
        case .idle:
            return 0
        case .focus:
            return 1
        case .shortBreak, .longBreak:
            switch duringBreaks {
            case .off: return 0
            case .lower: return Self.loweredLevel
            case .keep: return 1
            }
        }
    }
}

extension AmbientPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case duringBreaks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(duringBreaks: c.lenient(AmbientBreakBehavior.self, .duringBreaks) ?? .off)
    }
}
