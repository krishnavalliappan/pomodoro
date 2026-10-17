import Foundation
import PomodoroCore
import XCTest
@testable import Pomodoro

private final class FakeActivityScheduler: ActivityScheduling {
    private(set) var begun: [(ProcessInfo.ActivityOptions, String)] = []
    private(set) var ended = 0
    var active: Int { begun.count - ended }

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        begun.append((options, reason))
        return NSObject()
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        ended += 1
    }
}

@MainActor
final class AppNapGuardTests: XCTestCase {
    func testOptionsAllowIdleSleep() {
        XCTAssertTrue(AppNapGuard.options.contains(.userInitiated.subtracting(.idleSystemSleepDisabled)))
        XCTAssertFalse(AppNapGuard.options.contains(.idleSystemSleepDisabled))
    }

    func testHoldsOnlyWhileABoundaryIsComing() {
        let scheduler = FakeActivityScheduler()
        let guardian = AppNapGuard(scheduler: scheduler)
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let engine = TimerEngine(clock: clock)

        guardian.update(with: engine)
        XCTAssertFalse(guardian.isHolding, "idle")

        engine.start()
        guardian.update(with: engine)
        XCTAssertTrue(guardian.isHolding, "running")
        XCTAssertEqual(scheduler.begun.first?.0, AppNapGuard.options)

        engine.pause()
        guardian.update(with: engine)
        XCTAssertFalse(guardian.isHolding, "paused")

        engine.resume()
        clock.advance(by: 25 * 60)
        engine.reconcile()
        guardian.update(with: engine)
        XCTAssertTrue(guardian.isHolding, "overtime with nudges due")

        engine.keepGoing()
        guardian.update(with: engine)
        XCTAssertFalse(guardian.isHolding, "overtime with nudges silenced")
        XCTAssertEqual(scheduler.active, 0)
        XCTAssertEqual(scheduler.begun.count, 2)
    }

    func testRepeatedUpdatesHoldOneActivity() {
        let scheduler = FakeActivityScheduler()
        let guardian = AppNapGuard(scheduler: scheduler)
        guardian.setHolding(true)
        guardian.setHolding(true)
        XCTAssertEqual(scheduler.begun.count, 1)
        guardian.setHolding(false)
        guardian.setHolding(false)
        XCTAssertEqual(scheduler.ended, 1)
    }

    func testReleasingTheGuardEndsTheActivity() {
        let scheduler = FakeActivityScheduler()
        var guardian: AppNapGuard? = AppNapGuard(scheduler: scheduler)
        guardian?.setHolding(true)
        guardian = nil
        XCTAssertEqual(scheduler.active, 0)
    }
}
