import Foundation
import Testing
@testable import PomodoroCore

struct AmbientPolicyTests {
    private let overtime = TimerStatus.overtime(since: Date(timeIntervalSince1970: 0))

    @Test func defaultFadesOutForBreaks() {
        #expect(AmbientPolicy().duringBreaks == .off)
    }

    @Test(arguments: AmbientBreakBehavior.allCases)
    func focusPlaysAndEverythingStoppedIsSilent(_ behavior: AmbientBreakBehavior) {
        let policy = AmbientPolicy(duringBreaks: behavior)
        #expect(policy.level(phase: .focus, status: .running) == 1)
        #expect(policy.level(phase: .focus, status: overtime) == 1, "flow-mode overtime is still focus")
        #expect(policy.level(phase: .focus, status: .paused) == 0)
        #expect(policy.level(phase: .focus, status: .awaitingDecision) == 0)
        #expect(policy.level(phase: .idle, status: .awaitingDecision) == 0)
        #expect(policy.level(phase: .idle, status: .running) == 0)
        #expect(policy.level(phase: .shortBreak, status: .paused) == 0)
        #expect(policy.level(phase: .longBreak, status: .awaitingDecision) == 0)
    }

    @Test(arguments: [
        (AmbientBreakBehavior.off, 0.0),
        (.lower, AmbientPolicy.loweredLevel),
        (.keep, 1.0),
    ])
    func breaksFollowTheBehavior(_ behavior: AmbientBreakBehavior, _ expected: Double) {
        let policy = AmbientPolicy(duringBreaks: behavior)
        #expect(policy.level(phase: .shortBreak, status: .running) == expected)
        #expect(policy.level(phase: .longBreak, status: .running) == expected)
        #expect(policy.level(phase: .shortBreak, status: overtime) == expected)
    }

    /// A whole session as the app sees it: start, pause, resume, break, focus again, stop.
    static let sessions: [(AmbientBreakBehavior, [Double])] = [
        (.off, [0, 1, 0, 1, 0, 1, 0]),
        (.lower, [0, 1, 0, 1, AmbientPolicy.loweredLevel, 1, 0]),
        (.keep, [0, 1, 0, 1, 1, 1, 0]),
    ]

    @Test(arguments: sessions)
    func sessionTransitions(_ behavior: AmbientBreakBehavior, _ expected: [Double]) {
        let policy = AmbientPolicy(duringBreaks: behavior)
        let states: [(TimerPhase, TimerStatus)] = [
            (.idle, .awaitingDecision),
            (.focus, .running),
            (.focus, .paused),
            (.focus, overtime),
            (.shortBreak, .running),
            (.focus, .running),
            (.idle, .awaitingDecision),
        ]
        #expect(states.map { policy.level(phase: $0.0, status: $0.1) } == expected)
    }

    @Test func codable() throws {
        let policy = AmbientPolicy(duringBreaks: .lower)
        #expect(try JSONDecoder().decode(AmbientPolicy.self, from: try JSONEncoder().encode(policy)) == policy)
        let unknown = Data(#"{"duringBreaks": "louder"}"#.utf8)
        #expect(try JSONDecoder().decode(AmbientPolicy.self, from: unknown) == AmbientPolicy())
    }
}
