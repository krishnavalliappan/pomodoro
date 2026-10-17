import Foundation
import Testing
@testable import PomodoroCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let focus: TimeInterval = 25 * 60

private func makeEngine(_ configuration: TimerConfiguration = TimerConfiguration()) -> (TimerEngine, TestClock) {
    let clock = TestClock(now: t0)
    return (TimerEngine(configuration: configuration, clock: clock), clock)
}

/// Records carry random IDs, so compare event kinds instead of whole events.
private func kinds(_ events: [TimerEvent]) -> [String] {
    events.map { event in
        switch event {
        case .phaseStarted(let phase): "started:\(phase.rawValue)"
        case .focusEnded: "focusEnded"
        case .breakEnded: "breakEnded"
        case .nudge(let overtime): "nudge:\(Int(overtime))"
        case .sessionRecorded(let record): "recorded:\(record.outcome.rawValue)"
        }
    }
}

private func records(_ events: [TimerEvent]) -> [FocusSessionRecord] {
    events.compactMap { event -> FocusSessionRecord? in
        guard case .sessionRecorded(let record) = event else { return nil }
        return record
    }
}

/// Completes one focus at its planned end and starts the break due next.
private func completeFocus(_ engine: TimerEngine, _ clock: TestClock) -> TimerPhase {
    engine.start()
    clock.advance(by: focus)
    engine.startBreak()
    return engine.phase
}

struct ClockTests {
    @Test func testClockOnlyMovesWhenAdvanced() {
        let clock = TestClock(now: t0)
        #expect(clock.now == t0)
        clock.advance(by: 90)
        #expect(clock.now == t0 + 90)
        clock.now = t0
        #expect(clock.now == t0)
    }

    @Test func systemClockTracksWallClock() {
        #expect(abs(SystemClock().now.timeIntervalSinceNow) < 1)
    }
}

struct TimerEngineBasicsTests {
    @Test func startsIdle() {
        let (engine, _) = makeEngine()
        #expect(engine.phase == .idle)
        #expect(engine.status == .awaitingDecision)
        #expect(engine.nextBoundary == nil)
        #expect(engine.snapshot().remaining == 0)
        #expect(engine.reconcile().isEmpty)
    }

    @Test func startFocusUsesConfiguredDuration() {
        let (engine, _) = makeEngine()
        let id = UUID()
        let events = engine.start(taskID: id)
        #expect(kinds(events) == ["started:focus"])
        #expect(engine.phase == .focus)
        #expect(engine.status == .running)
        #expect(engine.taskID == id)
        #expect(engine.state.phaseStartedAt == t0)
        #expect(engine.nextBoundary == t0 + focus)
        #expect(engine.snapshot().remaining == focus)
    }

    @Test func remainingIsDerivedFromTheClockWithoutTicks() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 600)
        let snapshot = engine.snapshot()
        #expect(snapshot.elapsed == 600)
        #expect(snapshot.remaining == 900)
        #expect(snapshot.progress == 0.4)
        #expect(engine.snapshot(at: t0 + 1200).remaining == 300)
    }

    @Test func oneOffDurationDoesNotChangeConfiguration() {
        let (engine, clock) = makeEngine()
        engine.start(duration: 50 * 60)
        #expect(engine.nextBoundary == t0 + 3000)
        #expect(engine.configuration.focusDuration == focus)
        engine.stopAndLog()
        clock.advance(by: 10)
        engine.start()
        #expect(engine.snapshot().plannedDuration == focus)
    }

    @Test func configurationChangesDoNotAffectTheRunningPhase() {
        let (engine, _) = makeEngine()
        engine.start()
        engine.configuration.focusDuration = 10 * 60
        #expect(engine.nextBoundary == t0 + focus)
    }

    @Test func startingABreakDirectly() {
        let (engine, _) = makeEngine()
        #expect(kinds(engine.start(phase: .longBreak)) == ["started:longBreak"])
        #expect(engine.nextBoundary == t0 + 15 * 60)
    }

    @Test func startingIdleGoesIdle() {
        let (engine, _) = makeEngine()
        engine.start()
        let events = engine.start(phase: .idle)
        #expect(kinds(events) == ["recorded:abandoned"])
        #expect(engine.phase == .idle)
    }

    @Test func startWhileFocusingRecordsThePreviousSession() {
        let (engine, clock) = makeEngine()
        let first = UUID(), second = UUID()
        engine.start(taskID: first)
        clock.advance(by: 300)
        let events = engine.start(taskID: second)
        #expect(kinds(events) == ["recorded:abandoned", "started:focus"])
        #expect(records(events).first?.taskID == first)
        #expect(records(events).first?.activeDuration == 300)
        #expect(engine.taskID == second)
        #expect(engine.state.phaseStartedAt == t0 + 300)
    }

    @Test func onEventReceivesTheSameEventsInOrder() {
        let (engine, clock) = makeEngine()
        var received: [TimerEvent] = []
        engine.onEvent = { received.append($0) }
        let started = engine.start()
        clock.advance(by: focus)
        let ended = engine.reconcile()
        #expect(received == started + ended)
        #expect(kinds(received) == ["started:focus", "focusEnded"])
    }
}

struct TimerEnginePauseTests {
    @Test func pauseFreezesRemainingAndResumeShiftsTheBoundary() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 300)
        engine.pause()
        #expect(engine.status == .paused)
        #expect(engine.nextBoundary == nil)
        clock.advance(by: 600)
        #expect(engine.snapshot().remaining == 1200)
        #expect(engine.reconcile().isEmpty)
        engine.resume()
        #expect(engine.status == .running)
        #expect(engine.nextBoundary == t0 + focus + 600)
        clock.advance(by: 1199)
        #expect(engine.reconcile().isEmpty)
        clock.advance(by: 1)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
    }

    @Test func multiplePausesAccumulate() {
        let (engine, clock) = makeEngine()
        engine.start()
        for _ in 0..<3 {
            clock.advance(by: 100)
            engine.pause()
            clock.advance(by: 50)
            engine.resume()
        }
        #expect(engine.state.pausedAccumulated == 150)
        #expect(engine.snapshot().elapsed == 300)
        #expect(engine.nextBoundary == t0 + focus + 150)
    }

    @Test func pauseAndResumeAreNoOpsWhenNotApplicable() {
        let (engine, _) = makeEngine()
        engine.pause()
        engine.resume()
        #expect(engine.phase == .idle)
        engine.start()
        engine.resume()
        #expect(engine.status == .running)
        engine.pause()
        engine.pause()
        #expect(engine.status == .paused)
    }

    @Test func pausingThroughTheBoundaryDoesNotEndThePhase() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 1000)
        engine.pause()
        clock.advance(by: 3600)
        #expect(engine.reconcile().isEmpty)
        #expect(engine.snapshot().remaining == 500)
    }

    @Test func pauseDuringOvertimeFreezesOvertime() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        engine.reconcile()
        clock.advance(by: 300)
        engine.pause()
        clock.advance(by: 1000)
        #expect(engine.snapshot().overtime == 300)
        engine.resume()
        #expect(engine.status == .overtime(since: t0 + focus + 1000))
        clock.advance(by: 60)
        #expect(engine.snapshot().overtime == 360)
    }
}

struct TimerEngineOvertimeTests {
    @Test func focusEndEntersOvertimeAndKeepsCounting() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        #expect(engine.phase == .focus)
        #expect(engine.status == .overtime(since: t0 + focus))
        clock.advance(by: 192)
        let snapshot = engine.snapshot()
        #expect(snapshot.remaining == 0)
        #expect(snapshot.overtime == 192)
        #expect(snapshot.isOvertime)
        #expect(snapshot.progress == 1)
    }

    @Test func focusEndedIsEmittedOnce() {
        let (engine, clock) = makeEngine(TimerConfiguration(nudgeInterval: nil))
        engine.start()
        clock.advance(by: focus)
        var all = engine.reconcile()
        for _ in 0..<5 {
            clock.advance(by: 120)
            all += engine.reconcile()
        }
        #expect(kinds(all) == ["focusEnded"])
    }

    @Test func anyActionReconcilesFirst() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 10)
        let events = engine.pause()
        #expect(kinds(events) == ["focusEnded"])
        #expect(engine.status == .paused)
        #expect(engine.snapshot().overtime == 10)
    }

    @Test func nudgesRepeatEveryInterval() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        engine.reconcile()
        #expect(engine.nextBoundary == t0 + focus + 600)
        clock.advance(by: 599)
        #expect(engine.reconcile().isEmpty)
        clock.advance(by: 1)
        #expect(kinds(engine.reconcile()) == ["nudge:600"])
        #expect(engine.nextBoundary == t0 + focus + 1200)
        clock.advance(by: 300)
        #expect(engine.reconcile().isEmpty)
        clock.advance(by: 300)
        #expect(kinds(engine.reconcile()) == ["nudge:1200"])
    }

    @Test func nudgesCanBeTurnedOff() {
        for interval in [nil, 0] as [TimeInterval?] {
            let (engine, clock) = makeEngine(TimerConfiguration(nudgeInterval: interval))
            engine.start()
            clock.advance(by: focus)
            engine.reconcile()
            #expect(engine.nextBoundary == nil)
            clock.advance(by: 3600)
            #expect(engine.reconcile().isEmpty)
        }
    }

    @Test func missedNudgesCoalesceIntoOne() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 100)
        engine.reconcile()
        clock.advance(by: 2000)
        #expect(kinds(engine.reconcile()) == ["nudge:2100"])
        #expect(engine.nextBoundary == t0 + focus + 2400)
    }

    @Test func nudgeIntervalHonoursPausesInOvertime() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 300)
        engine.pause()
        clock.advance(by: 500)
        engine.resume()
        #expect(engine.nextBoundary == t0 + focus + 500 + 600)
        clock.advance(by: 299)
        #expect(engine.reconcile().isEmpty)
        clock.advance(by: 1)
        #expect(kinds(engine.reconcile()) == ["nudge:600"])
    }

    @Test func keepGoingSilencesNudgesButKeepsCounting() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        engine.reconcile()
        #expect(engine.keepGoing().isEmpty)
        #expect(engine.status == .overtime(since: t0 + focus))
        #expect(engine.nextBoundary == nil)
        clock.advance(by: 3600)
        #expect(engine.reconcile().isEmpty)
        #expect(engine.snapshot().overtime == 3600)
    }

    @Test func keepGoingIsANoOpWhileRunning() {
        let (engine, _) = makeEngine()
        engine.start()
        engine.keepGoing()
        #expect(engine.status == .running)
        #expect(engine.nextBoundary == t0 + focus)
    }

    @Test func breakEndCountsOvertimeAndNudges() {
        let (engine, clock) = makeEngine()
        engine.start(phase: .shortBreak)
        clock.advance(by: 300)
        #expect(kinds(engine.reconcile()) == ["breakEnded"])
        #expect(engine.phase == .shortBreak)
        #expect(engine.status == .overtime(since: t0 + 300))
        clock.advance(by: 600)
        #expect(kinds(engine.reconcile()) == ["nudge:600"])
        let events = engine.start(phase: .focus)
        #expect(kinds(events) == ["started:focus"])
    }
}

struct TimerEngineExtendTests {
    @Test func extendWhileRunningAddsToPlan() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 600)
        engine.extend(by: 60)
        engine.extend(by: 300)
        #expect(engine.snapshot().plannedDuration == focus + 360)
        #expect(engine.nextBoundary == t0 + focus + 360)
    }

    @Test func extendWhilePausedAddsToPlan() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 600)
        engine.pause()
        engine.extend(by: 300)
        #expect(engine.status == .paused)
        #expect(engine.snapshot().remaining == 1200)
    }

    @Test func extendInOvertimeGivesTimeFromNowAndEndsAgain() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 300)
        engine.reconcile()
        engine.extend(by: 300)
        #expect(engine.status == .running)
        #expect(engine.snapshot().remaining == 300)
        #expect(engine.nextBoundary == t0 + focus + 600)
        clock.advance(by: 300)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        #expect(engine.status == .overtime(since: t0 + focus + 600))
    }

    @Test func extendResetsSilencedNudges() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        engine.reconcile()
        engine.keepGoing()
        engine.extend(by: 60)
        clock.advance(by: 60)
        engine.reconcile()
        #expect(engine.nextBoundary == t0 + focus + 60 + 600)
    }

    @Test func extendIgnoresIdleAndNonPositiveAmounts() {
        let (engine, _) = makeEngine()
        engine.extend(by: 60)
        #expect(engine.phase == .idle)
        engine.start()
        engine.extend(by: 0)
        engine.extend(by: -60)
        #expect(engine.nextBoundary == t0 + focus)
    }
}

struct TimerEngineTransitionTests {
    @Test func startBreakFromOvertimeRecordsCompletedSession() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 200)
        engine.reconcile()
        let events = engine.startBreak()
        #expect(kinds(events) == ["recorded:completed", "started:shortBreak"])
        #expect(records(events).first?.overtime == 200)
        #expect(engine.phase == .shortBreak)
        #expect(engine.state.phaseStartedAt == t0 + focus + 200)
        #expect(engine.nextBoundary == t0 + focus + 200 + 300)
        #expect(engine.state.completedFocusesInCycle == 1)
    }

    @Test func startBreakDuringABreakIsANoOp() {
        let (engine, _) = makeEngine()
        engine.start(phase: .shortBreak)
        #expect(engine.startBreak().isEmpty)
    }

    @Test func startBreakFromIdleStartsTheDueBreak() {
        let (engine, _) = makeEngine()
        #expect(kinds(engine.startBreak()) == ["started:shortBreak"])
    }

    @Test func skipFocusEarlyIsAbandonedThenSkipBreakKeepsTask() {
        let (engine, clock) = makeEngine()
        let id = UUID()
        engine.start(taskID: id)
        clock.advance(by: 600)
        let skipped = engine.skip()
        #expect(kinds(skipped) == ["recorded:abandoned", "started:shortBreak"])
        #expect(records(skipped).first?.activeDuration == 600)
        #expect(engine.state.completedFocusesInCycle == 0)
        clock.advance(by: 60)
        #expect(kinds(engine.skip()) == ["started:focus"])
        #expect(engine.taskID == id)
        #expect(engine.state.phaseStartedAt == t0 + 660)
    }

    @Test func skipIdleDoesNothing() {
        let (engine, _) = makeEngine()
        #expect(engine.skip().isEmpty)
        #expect(engine.phase == .idle)
    }

    @Test func resetDiscardsWithoutLoggingAndClearsCadence() {
        let (engine, clock) = makeEngine()
        _ = completeFocus(engine, clock)
        engine.start(taskID: UUID())
        clock.advance(by: 600)
        #expect(engine.reset().isEmpty)
        #expect(engine.state == TimerState())
        #expect(engine.nextBoundary == nil)
    }

    @Test func stopAndLogEarlyIsAbandonedAndGoesIdle() throws {
        let (engine, clock) = makeEngine()
        let id = UUID()
        engine.start(taskID: id)
        clock.advance(by: 700)
        let events = engine.stopAndLog()
        let record = try #require(records(events).first)
        #expect(record.outcome == .abandoned)
        #expect(record.activeDuration == 700)
        #expect(record.overtime == 0)
        #expect(record.taskID == id)
        #expect(engine.phase == .idle)
        #expect(engine.state.completedFocusesInCycle == 0)
    }

    @Test func stopAndLogKeepsCadence() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 60)
        let events = engine.stopAndLog()
        #expect(kinds(events) == ["focusEnded", "recorded:completed"])
        #expect(engine.state.completedFocusesInCycle == 1)
        #expect(engine.nextBreakPhase == .shortBreak)
    }

    @Test func stopAndLogOnABreakIsDoneForNow() {
        let (engine, clock) = makeEngine()
        engine.start(phase: .shortBreak)
        clock.advance(by: 400)
        #expect(kinds(engine.stopAndLog()) == ["breakEnded"])
        #expect(engine.phase == .idle)
        #expect(engine.stopAndLog().isEmpty)
    }

    @Test func stopAndLogWhilePausedEndsAtThePause() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 400)
        engine.pause()
        clock.advance(by: 1000)
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.endedAt == t0 + 400)
        #expect(record.activeDuration == 400)
        #expect(record.pausedDuration == 0)
    }
}

struct TimerEngineCadenceTests {
    @Test func longBreakAfterEveryFourCompletedFocuses() {
        let (engine, clock) = makeEngine()
        var breaks: [TimerPhase] = []
        for _ in 0..<8 {
            breaks.append(completeFocus(engine, clock))
            if breaks.last == .longBreak { #expect(engine.state.completedFocusesInCycle == 0) }
        }
        #expect(breaks == [.shortBreak, .shortBreak, .shortBreak, .longBreak,
                           .shortBreak, .shortBreak, .shortBreak, .longBreak])
        #expect(engine.nextBoundary == clock.now + 15 * 60)
    }

    @Test func customLongBreakInterval() {
        let (engine, clock) = makeEngine(TimerConfiguration(longBreakEvery: 2))
        let breaks = (0..<4).map { _ in completeFocus(engine, clock) }
        #expect(breaks == [.shortBreak, .longBreak, .shortBreak, .longBreak])
    }

    @Test func longBreaksCanBeDisabled() {
        let (engine, clock) = makeEngine(TimerConfiguration(longBreakEvery: 0))
        let breaks = (0..<5).map { _ in completeFocus(engine, clock) }
        #expect(breaks.allSatisfy { $0 == .shortBreak })
    }

    @Test func abandonedFocusDoesNotAdvanceCadence() {
        let (engine, clock) = makeEngine(TimerConfiguration(longBreakEvery: 2))
        _ = completeFocus(engine, clock)
        engine.start()
        clock.advance(by: 60)
        engine.startBreak()
        #expect(engine.phase == .shortBreak)
        #expect(completeFocus(engine, clock) == .longBreak)
    }
}

struct TimerEngineAutoStartTests {
    @Test func autoStartBreakAtTheBoundary() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartBreaks: true))
        engine.start()
        clock.advance(by: focus + 30)
        let events = engine.reconcile()
        #expect(kinds(events) == ["focusEnded", "recorded:completed", "started:shortBreak"])
        let record = try #require(records(events).first)
        #expect(record.endedAt == t0 + focus)
        #expect(record.overtime == 0)
        #expect(engine.state.phaseStartedAt == t0 + focus)
        #expect(engine.snapshot().remaining == 270)
    }

    @Test func autoStartFocusAfterBreakKeepsTask() {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartFocus: true))
        let id = UUID()
        engine.start(taskID: id)
        clock.advance(by: focus)
        engine.startBreak()
        clock.advance(by: 330)
        #expect(kinds(engine.reconcile()) == ["breakEnded", "started:focus"])
        #expect(engine.taskID == id)
        #expect(engine.state.phaseStartedAt == t0 + focus + 300)
        #expect(engine.snapshot().remaining == focus - 30)
    }

    @Test func autoStartFocusIsSuppressedAfterSleep() {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartFocus: true))
        engine.start(phase: .shortBreak)
        clock.advance(by: 300 + TimerEngine.autoStartFocusGrace + 1)
        #expect(kinds(engine.reconcile()) == ["breakEnded"])
        #expect(engine.phase == .shortBreak)
        #expect(engine.status == .overtime(since: t0 + 300))
    }

    @Test func noAutoStartByDefault() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        engine.reconcile()
        #expect(engine.phase == .focus)
        engine.startBreak()
        clock.advance(by: 300)
        engine.reconcile()
        #expect(engine.phase == .shortBreak)
    }
}

struct TimerEngineReconcileTests {
    @Test func sleepOverFocusBoundaryShowsOvertimeWithoutNudgeBurst() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: 3600)
        #expect(engine.nextBoundary == t0 + focus)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        #expect(engine.status == .overtime(since: t0 + focus))
        #expect(engine.snapshot().overtime == 3600 - focus)
        #expect(engine.nextBoundary == t0 + focus + 4 * 600)
    }

    @Test func reconcileWithExplicitDate() {
        let (engine, _) = makeEngine()
        engine.start()
        #expect(engine.reconcile(now: t0 + 100).isEmpty)
        #expect(kinds(engine.reconcile(now: t0 + focus)) == ["focusEnded"])
    }

    @Test func fullAutoStartChainsAcrossSleepButNotIntoAFocus() {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartBreaks: true, autoStartFocus: true))
        engine.start()
        clock.advance(by: 7200)
        let events = engine.reconcile()
        #expect(kinds(events) == ["focusEnded", "recorded:completed", "started:shortBreak", "breakEnded"])
        #expect(records(events).first?.endedAt == t0 + focus)
        #expect(engine.phase == .shortBreak)
        #expect(engine.status == .overtime(since: t0 + focus + 300))
        #expect(engine.snapshot().overtime == 7200 - focus - 300)
    }

    @Test func autoStartChainsThroughCyclesWhileAwake() {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartBreaks: true, autoStartFocus: true))
        engine.start()
        var all: [TimerEvent] = []
        while let boundary = engine.nextBoundary, boundary <= t0 + 4 * (focus + 300) {
            clock.now = boundary
            all += engine.reconcile()
        }
        #expect(records(all).count == 4)
        #expect(records(all).allSatisfy { $0.outcome == .completed })
        #expect(engine.phase == .longBreak)
    }

    @Test func nonFlowModeFreezesAtZero() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(flowMode: false))
        engine.start()
        clock.advance(by: focus + 600)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        #expect(engine.status == .awaitingDecision)
        #expect(engine.nextBoundary == nil)
        let snapshot = engine.snapshot()
        #expect(snapshot.elapsed == focus)
        #expect(snapshot.remaining == 0)
        #expect(snapshot.overtime == 0)
        engine.pause()
        #expect(engine.status == .awaitingDecision)
        let record = try #require(records(engine.startBreak()).first)
        #expect(record.endedAt == t0 + focus)
        #expect(record.activeDuration == focus)
        #expect(record.outcome == .completed)
        #expect(engine.state.phaseStartedAt == t0 + focus + 600)
    }

    @Test func nonFlowModeKeepGoingCountsOvertimeFromNow() {
        let (engine, clock) = makeEngine(TimerConfiguration(flowMode: false))
        engine.start()
        clock.advance(by: focus + 600)
        engine.keepGoing()
        #expect(engine.status == .overtime(since: t0 + focus + 600))
        clock.advance(by: 60)
        #expect(engine.snapshot().overtime == 60)
        #expect(engine.nextBoundary == nil)
    }

    @Test func nonFlowModeExtendResumes() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(flowMode: false))
        engine.start()
        clock.advance(by: focus + 600)
        engine.extend(by: 300)
        #expect(engine.status == .running)
        #expect(engine.nextBoundary == t0 + focus + 900)
        clock.advance(by: 300)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        let record = try #require(records(engine.startBreak()).first)
        #expect(record.activeDuration == focus + 300)
        #expect(record.pausedDuration == 600)
    }

    @Test func nonFlowBreakEndsAwaitingDecision() {
        let (engine, clock) = makeEngine(TimerConfiguration(flowMode: false))
        engine.start(phase: .shortBreak)
        clock.advance(by: 400)
        #expect(kinds(engine.reconcile()) == ["breakEnded"])
        #expect(engine.status == .awaitingDecision)
    }
}

struct FocusSessionRecordTests {
    @Test func recordContentsWithPausesAndOvertime() throws {
        let (engine, clock) = makeEngine()
        let id = UUID()
        engine.start(taskID: id)
        clock.advance(by: 600)
        engine.pause()
        clock.advance(by: 120)
        engine.resume()
        clock.advance(by: 900 + 180)
        engine.reconcile()
        let record = try #require(records(engine.startBreak()).first)
        #expect(record.taskID == id)
        #expect(record.startedAt == t0)
        #expect(record.endedAt == t0 + 1800)
        #expect(record.plannedDuration == focus)
        #expect(record.activeDuration == 1680)
        #expect(record.pausedDuration == 120)
        #expect(record.overtime == 180)
        #expect(record.outcome == .completed)
        #expect(record.endedAt == record.startedAt + record.activeDuration + record.pausedDuration)
    }

    @Test func recordIncludesExtensionsInPlan() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        engine.extend(by: 300)
        clock.advance(by: focus + 400)
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.plannedDuration == focus + 300)
        #expect(record.overtime == 100)
        #expect(record.outcome == .completed)
    }

    @Test func recordWithoutTask() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus)
        let record = try #require(records(engine.skip()).first)
        #expect(record.taskID == nil)
        #expect(record.outcome == .completed)
    }

    @Test func breaksAreNeverRecorded() {
        let (engine, clock) = makeEngine()
        engine.start(phase: .shortBreak)
        clock.advance(by: 1000)
        let events = engine.reconcile() + engine.skip() + engine.reset()
        #expect(records(events).isEmpty)
    }
}

struct TimerStatePersistenceTests {
    @Test func stateRoundTripsAndRestoredEngineContinues() throws {
        let (engine, clock) = makeEngine()
        let id = UUID()
        engine.start(taskID: id)
        clock.advance(by: 300)
        engine.pause()
        let data = try JSONEncoder().encode(engine.state)
        let decoded = try JSONDecoder().decode(TimerState.self, from: data)
        #expect(decoded == engine.state)

        let restored = TimerEngine(clock: clock, state: decoded)
        clock.advance(by: 100)
        restored.resume()
        #expect(restored.taskID == id)
        #expect(restored.snapshot().remaining == 1200)
        #expect(restored.nextBoundary == t0 + focus + 100)
    }

    @Test func overtimeStatusRoundTrips() throws {
        let status = TimerStatus.overtime(since: t0)
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(TimerStatus.self, from: data) == status)
    }

    @Test func configurationDefaults() {
        let configuration = TimerConfiguration()
        #expect(configuration.duration(for: .focus) == 1500)
        #expect(configuration.duration(for: .shortBreak) == 300)
        #expect(configuration.duration(for: .longBreak) == 900)
        #expect(configuration.duration(for: .idle) == 0)
        #expect(configuration.longBreakEvery == 4)
        #expect(configuration.flowMode)
        #expect(configuration.nudgeInterval == 600)
        #expect(!configuration.autoStartBreaks)
        #expect(!configuration.autoStartFocus)
    }
}

private func isOvertime(_ status: TimerStatus) -> Bool {
    if case .overtime = status { true } else { false }
}

struct TimerEngineClockRollbackTests {
    @Test func rollbackWhileRunningKeepsElapsedAndShiftsTheBoundary() {
        let (engine, clock) = makeEngine(TimerConfiguration(nudgeInterval: nil))
        engine.start()
        clock.now = t0 + 1000
        engine.reconcile()
        clock.now = t0 + 400
        #expect(engine.reconcile().isEmpty)
        #expect(engine.snapshot().elapsed == 1000)
        #expect(engine.nextBoundary == t0 + 900)
        clock.now = t0 + 900
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
    }

    @Test func rollbackDuringPausedOvertimeDoesNotUndoTheEnd() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(nudgeInterval: nil))
        engine.start()
        clock.now = t0 + focus
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        clock.now = t0 + 1800
        engine.pause()
        clock.now = t0 + 1200
        #expect(engine.resume().isEmpty)
        #expect(isOvertime(engine.status))
        #expect(engine.snapshot().overtime == 300)
        clock.advance(by: 600)
        #expect(engine.reconcile().isEmpty)
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.outcome == .completed)
        #expect(record.activeDuration == 2400)
        #expect(record.overtime == 900)
        #expect(record.endedAt == record.startedAt + record.activeDuration + record.pausedDuration)
    }

    @Test func rollbackInOvertimeKeepsOvertime() {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.now = t0 + focus + 100
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        clock.now = t0 + 1000
        #expect(engine.reconcile().isEmpty)
        #expect(engine.snapshot().overtime == 100)
        #expect(engine.status == .overtime(since: t0 + 900))
        #expect(engine.nextBoundary == t0 + 900 + 600)
    }

    @Test func rollbackBeforeTheStartKeepsTheRecordValid() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.now = t0 + 1000
        engine.reconcile()
        clock.now = t0 - 500
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.activeDuration == 1000)
        #expect(record.startedAt == t0 - 1500)
        #expect(record.endedAt == t0 - 500)
        #expect(record.outcome == .abandoned)
    }

    @Test func rollbackWhileIdleStartsFromTheNewTime() {
        let (engine, clock) = makeEngine()
        engine.start()
        engine.reset()
        clock.now = t0 - 3600
        engine.start()
        #expect(engine.state.phaseStartedAt == t0 - 3600)
        #expect(engine.nextBoundary == t0 - 3600 + focus)
    }

    @Test func rollbackIsDetectedAfterRestore() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(nudgeInterval: nil))
        engine.start()
        clock.now = t0 + 1000
        engine.reconcile()
        let data = try JSONEncoder().encode(engine.state)
        clock.now = t0 + 400
        let restored = TimerEngine(clock: clock, state: try JSONDecoder().decode(TimerState.self, from: data))
        #expect(restored.reconcile().isEmpty)
        #expect(restored.snapshot().elapsed == 1000)
        #expect(restored.nextBoundary == t0 + 900)
    }
}

struct TimerEngineBoundaryTests {
    @Test(arguments: [TimerPhase.focus, .shortBreak])
    func resumingJustBeforeTheBoundaryStillEndsThePhaseOnce(phase: TimerPhase) throws {
        let (engine, clock) = makeEngine(TimerConfiguration(nudgeInterval: nil))
        engine.start(phase: phase)
        let planned = engine.snapshot().plannedDuration
        clock.now = t0 + planned - 0.0005
        engine.pause()
        clock.advance(by: 100)
        #expect(engine.resume().isEmpty)
        #expect(engine.status == .running)
        let boundary = try #require(engine.nextBoundary)
        #expect(abs(boundary.timeIntervalSince(t0 + planned + 100)) < 0.001)
        clock.now = boundary
        #expect(kinds(engine.reconcile()) == [phase == .focus ? "focusEnded" : "breakEnded"])
        clock.advance(by: 3600)
        #expect(engine.reconcile().isEmpty)
    }
}

struct TimerEngineNudgeIntervalChangeTests {
    /// Reaches overtime and takes the 600 s nudges at +600 and +1200 by jumping to each advertised boundary.
    private func engineAfterTwoNudges() -> (TimerEngine, TestClock) {
        let (engine, clock) = makeEngine()
        engine.start()
        while let boundary = engine.nextBoundary, boundary <= t0 + focus + 1200 {
            clock.now = boundary
            engine.reconcile()
        }
        return (engine, clock)
    }

    @Test func increasingTheIntervalCountsFromTheLastNudge() {
        let (engine, clock) = engineAfterTwoNudges()
        engine.configuration.nudgeInterval = 1200
        #expect(engine.nextBoundary == t0 + focus + 2400)
        clock.now = t0 + focus + 2400
        #expect(kinds(engine.reconcile()) == ["nudge:2400"])
        #expect(engine.nextBoundary == t0 + focus + 3600)
    }

    @Test func decreasingTheIntervalCountsFromTheLastNudge() {
        let (engine, clock) = engineAfterTwoNudges()
        clock.advance(by: 100)
        engine.configuration.nudgeInterval = 300
        #expect(engine.nextBoundary == t0 + focus + 1500)
        clock.now = t0 + focus + 1500
        #expect(kinds(engine.reconcile()) == ["nudge:1500"])
        #expect(engine.nextBoundary == t0 + focus + 1800)
    }

    @Test func decreasingPastTheNextNudgeRestartsFromNowWithoutNudging() {
        let (engine, clock) = engineAfterTwoNudges()
        clock.advance(by: 500)
        engine.configuration.nudgeInterval = 300
        #expect(engine.nextBoundary == t0 + focus + 2000)
        #expect(engine.reconcile().isEmpty)
    }

    @Test func disablingAndReenablingRestartsFromNow() {
        let (engine, clock) = engineAfterTwoNudges()
        engine.configuration.nudgeInterval = nil
        #expect(engine.nextBoundary == nil)
        clock.now = t0 + focus + 2500
        #expect(engine.reconcile().isEmpty)
        engine.configuration.nudgeInterval = 600
        #expect(engine.nextBoundary == t0 + focus + 3100)
        #expect(engine.reconcile().isEmpty)
        clock.now = t0 + focus + 3100
        #expect(kinds(engine.reconcile()) == ["nudge:3100"])
    }

    @Test func restoringWithADifferentIntervalCountsFromTheLastNudge() throws {
        let (engine, clock) = engineAfterTwoNudges()
        let data = try JSONEncoder().encode(engine.state)
        let restored = TimerEngine(
            configuration: TimerConfiguration(nudgeInterval: 1200),
            clock: clock,
            state: try JSONDecoder().decode(TimerState.self, from: data)
        )
        #expect(restored.nextBoundary == t0 + focus + 2400)
    }
}

struct TimerEngineResetTests {
    @Test(arguments: [0, 60] as [TimeInterval])
    func resetAtOrAfterAnOverdueBoundaryDeliversNothing(lateness: TimeInterval) {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartBreaks: true, autoStartFocus: true))
        var delivered: [TimerEvent] = []
        engine.onEvent = { delivered.append($0) }
        engine.start()
        delivered.removeAll()
        clock.advance(by: focus + lateness)
        #expect(engine.reset().isEmpty)
        #expect(delivered.isEmpty)
        #expect(engine.state == TimerState())
        #expect(engine.nextBoundary == nil)
    }
}

struct TimerEngineDurationValidationTests {
    private let everythingZero = TimerConfiguration(
        focusDuration: 0, shortBreakDuration: 0, longBreakDuration: 0,
        autoStartBreaks: true, autoStartFocus: true
    )

    @Test func zeroDurationsAreRaisedToTheMinimumAndTheChainTerminates() {
        let (engine, clock) = makeEngine(everythingZero)
        engine.start()
        #expect(engine.snapshot().plannedDuration == TimerEngine.minimumPhaseDuration)
        #expect(engine.nextBoundary == t0 + TimerEngine.minimumPhaseDuration)
        clock.advance(by: 30)
        let events = engine.reconcile()
        #expect(kinds(events).filter { $0.hasPrefix("started:") }.count == TimerEngine.maxChainedAutoStarts)
        #expect(isOvertime(engine.status))
    }

    @Test(arguments: [0, -60] as [TimeInterval])
    func nonPositiveOverridesAreRaisedToTheMinimum(duration: TimeInterval) {
        let (engine, clock) = makeEngine(everythingZero)
        engine.start(duration: duration)
        #expect(engine.snapshot().plannedDuration == TimerEngine.minimumPhaseDuration)
        clock.advance(by: 3600)
        engine.reconcile()
        #expect(engine.phase != .idle)
    }

    @Test func negativeConfiguredDurationsAreRaisedToTheMinimum() {
        let (engine, _) = makeEngine(TimerConfiguration(focusDuration: -300))
        engine.start()
        #expect(engine.snapshot().plannedDuration == TimerEngine.minimumPhaseDuration)
    }

    @Test func restoredZeroLengthPhaseTerminates() {
        var state = TimerState()
        state.phase = .focus
        state.status = .running
        state.phaseStartedAt = t0
        state.plannedDuration = 0
        let clock = TestClock(now: t0 + 10)
        let engine = TimerEngine(configuration: everythingZero, clock: clock, state: state)
        let events = engine.reconcile()
        #expect(kinds(events).first == "focusEnded")
        #expect(kinds(events).filter { $0.hasPrefix("started:") }.count <= TimerEngine.maxChainedAutoStarts)
    }

    @Test func shortPhasesWithinTheCapChainNormally() {
        let (engine, clock) = makeEngine(TimerConfiguration(
            focusDuration: 1, shortBreakDuration: 1, longBreakEvery: 0,
            nudgeInterval: nil, autoStartBreaks: true, autoStartFocus: true
        ))
        engine.start()
        clock.advance(by: 3)
        #expect(kinds(engine.reconcile()) == [
            "focusEnded", "recorded:completed", "started:shortBreak",
            "breakEnded", "started:focus",
            "focusEnded", "recorded:completed", "started:shortBreak",
        ])
        #expect(engine.status == .running)
    }
}

struct TimerEngineReviewFollowUpTests {
    @Test func autoStartFocusAtExactlyTheGrace() {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartFocus: true))
        engine.start(phase: .shortBreak)
        clock.advance(by: 300 + TimerEngine.autoStartFocusGrace)
        #expect(kinds(engine.reconcile()) == ["breakEnded", "started:focus"])
        #expect(engine.state.phaseStartedAt == t0 + 300)
    }

    @Test func extendInOvertimeAbsorbsAccruedOvertimeIntoThePlan() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 300)
        engine.reconcile()
        engine.extend(by: 300)
        clock.advance(by: 400)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.plannedDuration == focus + 600)
        #expect(record.activeDuration == focus + 700)
        #expect(record.overtime == 100)
        #expect(record.outcome == .completed)
    }

    @Test func extendInPausedOvertimeResumesRunning() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.advance(by: focus + 300)
        engine.reconcile()
        engine.pause()
        clock.advance(by: 200)
        engine.extend(by: 300)
        engine.resume()
        #expect(engine.status == .running)
        #expect(engine.nextBoundary == t0 + focus + 800)
        clock.advance(by: 400)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.plannedDuration == focus + 600)
        #expect(record.activeDuration == focus + 700)
        #expect(record.pausedDuration == 200)
        #expect(record.overtime == 100)
        #expect(record.outcome == .completed)
    }

    @Test func nextBreakPreviewCountsAFocusThatHasReachedItsEnd() {
        let (engine, clock) = makeEngine()
        for _ in 0..<3 { _ = completeFocus(engine, clock) }
        engine.start()
        #expect(engine.nextBreakPhase == .shortBreak)
        clock.advance(by: focus + 60)
        engine.reconcile()
        #expect(engine.nextBreakPhase == .longBreak)
        engine.startBreak()
        #expect(engine.phase == .longBreak)
    }

    @Test func autoCycleHitsIndependentlyComputedBoundaries() {
        let (engine, clock) = makeEngine(TimerConfiguration(longBreakEvery: 2, autoStartBreaks: true, autoStartFocus: true))
        engine.start()
        let schedule: [(TimeInterval, [String])] = [
            (1500, ["focusEnded", "recorded:completed", "started:shortBreak"]),
            (1800, ["breakEnded", "started:focus"]),
            (3300, ["focusEnded", "recorded:completed", "started:longBreak"]),
            (4200, ["breakEnded", "started:focus"]),
            (5700, ["focusEnded", "recorded:completed", "started:shortBreak"]),
        ]
        for (offset, expected) in schedule {
            #expect(engine.nextBoundary == t0 + offset)
            clock.now = t0 + offset - 1
            #expect(engine.reconcile().isEmpty)
            clock.now = t0 + offset
            #expect(kinds(engine.reconcile()) == expected)
        }
    }

    @Test func overtimeWithNudgesRoundTripsAndContinues() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.now = t0 + focus + 700
        engine.reconcile()
        clock.now = t0 + focus + 1300
        #expect(kinds(engine.reconcile()) == ["nudge:1300"])
        let data = try JSONEncoder().encode(engine.state)
        let decoded = try JSONDecoder().decode(TimerState.self, from: data)
        #expect(decoded == engine.state)
        let restored = TimerEngine(clock: clock, state: decoded)
        #expect(restored.nextBoundary == t0 + focus + 1800)
        #expect(restored.reconcile().isEmpty)
        clock.now = t0 + focus + 1800
        #expect(kinds(restored.reconcile()) == ["nudge:1800"])
    }

    @Test func silencedOvertimeRoundTrips() throws {
        let (engine, clock) = makeEngine()
        engine.start()
        clock.now = t0 + focus + 100
        engine.reconcile()
        engine.keepGoing()
        let data = try JSONEncoder().encode(engine.state)
        let restored = TimerEngine(clock: clock, state: try JSONDecoder().decode(TimerState.self, from: data))
        #expect(restored.nextBoundary == nil)
        clock.advance(by: 7200)
        #expect(restored.reconcile().isEmpty)
        #expect(restored.snapshot().overtime == 7300)
    }

    @Test func awaitingDecisionRoundTrips() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(flowMode: false))
        engine.start()
        clock.now = t0 + focus + 100
        engine.reconcile()
        let data = try JSONEncoder().encode(engine.state)
        let restored = TimerEngine(
            configuration: TimerConfiguration(flowMode: false),
            clock: clock,
            state: try JSONDecoder().decode(TimerState.self, from: data)
        )
        clock.advance(by: 600)
        #expect(restored.reconcile().isEmpty)
        let record = try #require(records(restored.startBreak()).first)
        #expect(record.endedAt == t0 + focus)
        #expect(record.outcome == .completed)
    }
}

struct TimerEngineFocusConfigurationTests {
    private let oneOff = TimerConfiguration(focusDuration: 50 * 60, shortBreakDuration: 10 * 60, longBreakDuration: 10 * 60)

    /// Hands out `oneOff` once, then the defaults, like the app's planner.
    private func attachOneOff(_ engine: TimerEngine) -> () -> Int {
        var queued: TimerConfiguration? = oneOff
        var asked = 0
        engine.configurationForFocus = {
            asked += 1
            defer { queued = nil }
            return queued ?? TimerConfiguration()
        }
        return { asked }
    }

    @Test func providerIsAskedForEveryFocusAndNotForBreaks() {
        let (engine, clock) = makeEngine()
        let asked = attachOneOff(engine)
        engine.start()
        #expect(asked() == 1)
        #expect(engine.state.plannedDuration == 50 * 60)
        engine.skip()
        #expect(asked() == 1, "a break keeps the focus's configuration")
        #expect(engine.state.plannedDuration == 10 * 60)
        clock.advance(by: 60)
        engine.skip()
        #expect(asked() == 2)
        #expect(engine.state.plannedDuration == focus)
    }

    @Test func chainedAutoStartsSwitchBackWithinOneCatchUp() {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartBreaks: true, autoStartFocus: true))
        var queued: TimerConfiguration? = TimerConfiguration(
            focusDuration: 50 * 60, shortBreakDuration: 10 * 60, longBreakDuration: 10 * 60,
            autoStartBreaks: true, autoStartFocus: true
        )
        engine.configurationForFocus = {
            defer { queued = nil }
            return queued ?? TimerConfiguration(autoStartBreaks: true, autoStartFocus: true)
        }
        engine.start()
        // Minute 60: the one-off focus and its break both ended, and the next focus auto-started.
        clock.advance(by: 60 * 60)
        let events = engine.reconcile()
        #expect(kinds(events) == [
            "focusEnded", "recorded:completed", "started:shortBreak", "breakEnded", "started:focus",
        ])
        #expect(engine.phase == .focus)
        #expect(engine.state.plannedDuration == focus, "the chained focus is back on the default")
        #expect(engine.configuration.shortBreakDuration == 5 * 60, "and so is its break")
    }

    @Test func explicitDurationStillWinsAndNilKeepsTheConfiguration() {
        let (engine, _) = makeEngine()
        engine.configurationForFocus = { nil }
        engine.start(duration: 600)
        #expect(engine.state.plannedDuration == 600)
        #expect(engine.configuration == TimerConfiguration())
    }
}

/// A provider that calls back into the engine is ignored, not replayed (release-build behaviour;
/// DEBUG traps, so these tests turn the trap off).
struct TimerEngineReentryTests {
    private func breakAtItsEnd() -> (TimerEngine, TestClock) {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartFocus: true))
        engine.trapsOnReentry = false
        engine.start(phase: .shortBreak)
        clock.advance(by: 5 * 60)
        return (engine, clock)
    }

    @Test func nestedReconcileFromTheProviderDoesNotReplayTheBreakEnd() {
        let (engine, _) = breakAtItsEnd()
        var asked = 0
        var nested: [[TimerEvent]] = []
        engine.configurationForFocus = {
            asked += 1
            nested.append(engine.reconcile())
            return nil
        }
        var delivered: [TimerEvent] = []
        engine.onEvent = { delivered.append($0) }
        let events = engine.reconcile()
        #expect(asked == 1)
        #expect(nested.allSatisfy { $0.isEmpty })
        #expect(kinds(events) == ["breakEnded", "started:focus"])
        #expect(kinds(delivered) == kinds(events))
        #expect(engine.phase == .focus)
        #expect(engine.status == .running)
        #expect(engine.state.plannedDuration == focus)
    }

    @Test func nestedActionsFromTheProviderAreIgnored() {
        let (engine, clock) = breakAtItsEnd()
        var asked = 0
        var nested: [[TimerEvent]] = []
        engine.configurationForFocus = {
            asked += 1
            nested = [engine.reset(), engine.start(phase: .longBreak), engine.skip(), engine.stopAndLog()]
            engine.configuration = TimerConfiguration(focusDuration: 1)
            _ = engine.snapshot()
            return TimerConfiguration(focusDuration: 40 * 60, autoStartFocus: true)
        }
        let events = engine.reconcile()
        #expect(asked == 1)
        #expect(nested.count == 4)
        #expect(nested.allSatisfy { $0.isEmpty })
        #expect(kinds(events) == ["breakEnded", "started:focus"])
        #expect(engine.phase == .focus)
        #expect(engine.state.plannedDuration == 40 * 60, "the provider's result wins over its ignored setter call")
        #expect(engine.state.phaseStartedAt == t0 + 5 * 60)

        // The guard lifts once the transition commits.
        engine.configurationForFocus = nil
        clock.advance(by: 60)
        #expect(kinds(engine.skip()) == ["recorded:abandoned", "started:shortBreak"])
    }

    @Test func providerThatStartsAFocusDoesNotRecurse() {
        let (engine, _) = makeEngine()
        engine.trapsOnReentry = false
        var asked = 0
        engine.configurationForFocus = {
            asked += 1
            engine.start()
            return nil
        }
        let events = engine.start()
        #expect(asked == 1)
        #expect(kinds(events) == ["started:focus"])
    }

    @Test func onEventMayCallBackInAfterTheTransitionCommits() {
        let (engine, _) = breakAtItsEnd()
        engine.trapsOnReentry = true
        var nested: [TimerEvent] = []
        var count = 0
        engine.onEvent = { event in
            count += 1
            if case .breakEnded = event { nested += engine.reconcile() }
        }
        let events = engine.reconcile()
        #expect(kinds(events) == ["breakEnded", "started:focus"])
        #expect(nested.isEmpty, "the end was already committed, so nothing replays")
        #expect(count == 2)
        #expect(engine.phase == .focus)
    }
}

struct TimerEngineAssignTaskTests {
    @Test func switchingMidFocusReattributesTheWholeSession() throws {
        let (engine, clock) = makeEngine()
        let first = UUID()
        let second = UUID()
        engine.start(taskID: first)
        clock.advance(by: 600)
        let snapshotBefore = engine.snapshot()
        #expect(engine.assignTask(second).isEmpty)
        #expect(engine.taskID == second)
        #expect(engine.snapshot().elapsed == snapshotBefore.elapsed, "timing is untouched")
        #expect(engine.nextBoundary == t0 + focus)

        clock.advance(by: focus - 600)
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.taskID == second)
        #expect(record.startedAt == t0)
        #expect(record.outcome == .completed)
    }

    @Test func clearingTheTaskRecordsNone() throws {
        let (engine, clock) = makeEngine()
        engine.start(taskID: UUID())
        clock.advance(by: 60)
        engine.assignTask(nil)
        let record = try #require(records(engine.stopAndLog()).first)
        #expect(record.taskID == nil)
    }

    @Test func idleIgnoresIt() {
        let (engine, _) = makeEngine()
        #expect(engine.assignTask(UUID()).isEmpty)
        #expect(engine.taskID == nil)
        #expect(engine.phase == .idle)
    }

    @Test func assigningDuringABreakCarriesIntoTheNextFocus() throws {
        let (engine, clock) = makeEngine()
        let first = UUID()
        let second = UUID()
        engine.start(taskID: first)
        clock.advance(by: focus)
        let ended = engine.startBreak()
        #expect(records(ended).first?.taskID == first)
        engine.assignTask(second)
        engine.skip()
        #expect(engine.phase == .focus)
        #expect(engine.taskID == second)
        clock.advance(by: 60)
        #expect(records(engine.stopAndLog()).first?.taskID == second)
    }

    @Test func reconcilesFirstSoAnOverdueEndIsStillDelivered() {
        let (engine, clock) = makeEngine()
        engine.start(taskID: UUID())
        clock.advance(by: focus + 30)
        #expect(kinds(engine.assignTask(UUID())) == ["focusEnded"])
    }

    @Test func afterADeliveredEndItEmitsNothingMore() {
        let (engine, clock) = makeEngine()
        engine.start(taskID: UUID())
        clock.advance(by: focus + 30)
        #expect(kinds(engine.reconcile()) == ["focusEnded"])
        let second = UUID()
        #expect(engine.assignTask(second).isEmpty, "no second end")
        #expect(engine.taskID == second)
        #expect(engine.status == .overtime(since: t0 + focus), "timing is untouched")
    }

    @Test func pausedStaysPausedThroughARestore() throws {
        let (engine, clock) = makeEngine()
        engine.start(taskID: UUID())
        clock.advance(by: 300)
        engine.pause()
        let id = UUID()
        #expect(engine.assignTask(id).isEmpty)
        let data = try JSONEncoder().encode(engine.state)
        let restored = TimerEngine(clock: clock, state: try JSONDecoder().decode(TimerState.self, from: data))
        #expect(restored.taskID == id)
        #expect(restored.status == .paused)
        #expect(restored.snapshot().elapsed == 300)
    }

    /// An overdue boundary auto-starts the break first, so the finished focus keeps its task.
    @Test func anOverdueAutoStartRecordsTheOldTaskFirst() throws {
        let (engine, clock) = makeEngine(TimerConfiguration(autoStartBreaks: true))
        let first = UUID()
        let second = UUID()
        engine.start(taskID: first)
        clock.advance(by: focus + 30)
        let events = engine.assignTask(second)
        #expect(records(events).map(\.taskID) == [first])
        #expect(engine.phase == .shortBreak)
        #expect(engine.taskID == second)
        engine.skip()
        #expect(engine.phase == .focus)
        #expect(engine.taskID == second)
    }

    @Test func survivesPersistence() throws {
        let (engine, clock) = makeEngine()
        let id = UUID()
        engine.start()
        engine.assignTask(id)
        let data = try JSONEncoder().encode(engine.state)
        let restored = TimerEngine(clock: clock, state: try JSONDecoder().decode(TimerState.self, from: data))
        #expect(restored.taskID == id)
    }
}
