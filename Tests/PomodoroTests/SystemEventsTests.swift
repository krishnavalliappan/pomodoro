import AppKit
import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
final class SystemEventsTests: XCTestCase {
    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()
    private let local = NotificationCenter()

    private func makeEvents(_ count: @escaping @MainActor () -> Void) -> SystemEvents {
        SystemEvents(workspaceCenter: workspace, distributedCenter: distributed, localCenter: local, reconcile: count)
    }

    func testEveryObservedNotificationReconcilesOnce() {
        let calls = Counter()
        let events = makeEvents { calls.value += 1 }
        let cases: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, SystemEvents.screenLocked),
            (distributed, SystemEvents.screenUnlocked),
            (local, .NSSystemClockDidChange),
        ]
        for (center, name) in cases {
            let before = calls.value
            center.post(name: name, object: nil)
            XCTAssertEqual(calls.value, before + 1, "\(name.rawValue)")
        }
        withExtendedLifetime(events) {}
    }

    func testUnrelatedNotificationsAndCentersAreIgnored() {
        let calls = Counter()
        let events = makeEvents { calls.value += 1 }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        local.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: .NSSystemClockDidChange, object: nil)
        XCTAssertEqual(calls.value, 0)
        withExtendedLifetime(events) {}
    }

    func testOffMainThreadPostReconcilesOnTheMainActor() async {
        let reconciled = expectation(description: "reconcile")
        let events = makeEvents {
            MainActor.assertIsolated()
            reconciled.fulfill()
        }
        let local = self.local
        DispatchQueue.global().async { local.post(name: .NSSystemClockDidChange, object: nil) }
        await fulfillment(of: [reconciled], timeout: 5)
        withExtendedLifetime(events) {}
    }

    func testReleasingStopsObserving() {
        let calls = Counter()
        var events: SystemEvents? = makeEvents { calls.value += 1 }
        weak let weakEvents = events
        events = nil
        XCTAssertNil(weakEvents)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(calls.value, 0)
    }

    func testReconcilesTheEngineAfterWake() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let engine = TimerEngine(clock: clock)
        let ends = Counter()
        let systemEvents = makeEvents { ends.value += engine.reconcile().filter { $0 == .focusEnded }.count }
        engine.start()
        clock.advance(by: 25 * 60 + 5)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(ends.value, 1)
        XCTAssertTrue(engine.snapshot().isOvertime)
        withExtendedLifetime(systemEvents) {}
    }
}
