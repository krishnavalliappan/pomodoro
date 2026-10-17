import Foundation
import Testing
@testable import PomodoroCore

struct TimerStateStoreTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PomodoroCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func nothingSavedLoadsNil() {
        withSuite { defaults in
            #expect(UserDefaultsTimerStateStore(defaults: defaults).load() == nil)
        }
    }

    @Test func unreadableDataLoadsNil() {
        withSuite { defaults in
            defaults.set(Data("nope".utf8), forKey: UserDefaultsTimerStateStore.defaultKey)
            #expect(UserDefaultsTimerStateStore(defaults: defaults).load() == nil)
        }
    }

    @Test func runningSessionSurvivesARoundTrip() throws {
        try withSuite { defaults in
            let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
            let profile = TimerProfile(focusDuration: 50 * 60, shortBreakDuration: 10 * 60, longBreakDuration: 20 * 60, nudgeInterval: nil)
            let engine = TimerEngine(configuration: TimerConfiguration(profile: profile), clock: clock)
            engine.start(taskID: UUID())
            clock.advance(by: 300)
            engine.pause()
            clock.advance(by: 60)

            try UserDefaultsTimerStateStore(defaults: defaults).save(PersistedTimer(state: engine.state, profile: profile))
            let loaded = try #require(UserDefaultsTimerStateStore(defaults: defaults).load())
            #expect(loaded.state == engine.state)
            #expect(loaded.profile == profile)

            let restored = TimerEngine(configuration: TimerConfiguration(profile: loaded.profile), clock: clock, state: loaded.state)
            #expect(restored.snapshot() == engine.snapshot())
            restored.resume()
            clock.advance(by: 45 * 60)
            #expect(restored.reconcile().contains(.focusEnded))
        }
    }

    @Test func overtimeStatusRoundTrips() throws {
        let clock = TestClock()
        let engine = TimerEngine(clock: clock)
        engine.start()
        clock.advance(by: 26 * 60)
        engine.reconcile()
        let store = InMemoryTimerStateStore()
        try store.save(PersistedTimer(state: engine.state, profile: .classic))
        let data = try JSONEncoder().encode(store.load())
        let decoded = try JSONDecoder().decode(PersistedTimer.self, from: data)
        #expect(decoded.state.status == .overtime(since: clock.now - 60))
    }
}
