import Foundation
import Testing
@testable import PomodoroCore

struct TimerBridgeTests {
    @Test func configurationMirrorsProfileFieldForField() {
        let profile = TimerProfile(
            focusDuration: 50 * 60, shortBreakDuration: 10 * 60, longBreakDuration: 20 * 60,
            longBreakEvery: 3, autoStartBreaks: true, autoStartFocus: true, flowMode: false, nudgeInterval: nil
        )
        let configuration = TimerConfiguration(profile: profile)
        #expect(configuration == TimerConfiguration(
            focusDuration: 50 * 60, shortBreakDuration: 10 * 60, longBreakDuration: 20 * 60,
            longBreakEvery: 3, flowMode: false, nudgeInterval: nil, autoStartBreaks: true, autoStartFocus: true
        ))
    }

    @Test func classicProfileMatchesEngineDefaults() {
        #expect(TimerConfiguration(profile: .classic) == TimerConfiguration())
    }

    @Test func overriddenProfileReachesTheEngine() {
        var planner = SessionPlanner()
        planner.setOverride(SessionOverride(parsing: "40/8"))
        let configuration = TimerConfiguration(profile: planner.consumeProfile(base: .classic))
        #expect(configuration.focusDuration == 40 * 60)
        #expect(configuration.shortBreakDuration == 8 * 60)
        #expect(configuration.longBreakDuration == 8 * 60)
        #expect(planner.pendingOverride == nil)
    }

    @Test func recordBridgesToAStorableSession() throws {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let engine = TimerEngine(clock: clock)
        let db = try AppDatabase.inMemory()
        let task = try db.tasks.create(title: "Write spec").id
        engine.start(taskID: task)
        clock.advance(by: 600)
        engine.pause()
        clock.advance(by: 120)
        engine.resume()
        clock.advance(by: 25 * 60)
        let events = engine.stopAndLog()
        let record = try #require(events.compactMap { event -> FocusSessionRecord? in
            if case .sessionRecorded(let record) = event { record } else { nil }
        }.first)

        let session = FocusSession(record: record)
        #expect(session.id == record.id)
        #expect(session.taskID == task)
        #expect(session.blockID == nil)
        #expect(session.start == record.startedAt)
        #expect(session.end == record.endedAt)
        #expect(session.plannedSeconds == 25 * 60)
        #expect(session.activeSeconds == 35 * 60)
        #expect(session.pausedSeconds == 120)
        #expect(session.overtimeSeconds == 10 * 60)
        #expect(session.completed)
        #expect(session.hasValidTiming)

        try db.sessions.insert(session)
        #expect(try db.sessions.fetch(id: session.id) == session)
    }

    @Test func abandonedRecordIsNotCompleted() throws {
        let clock = TestClock()
        let engine = TimerEngine(clock: clock)
        engine.start()
        clock.advance(by: 60)
        let record = try #require(engine.skip().compactMap { event -> FocusSessionRecord? in
            if case .sessionRecorded(let record) = event { record } else { nil }
        }.first)
        #expect(!FocusSession(record: record).completed)
    }
}
