import AppKit
import Foundation
import Observation
import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
final class PopoverNavigationTests: XCTestCase {
    func testStartsOnTheTimerTab() {
        XCTAssertEqual(PopoverNavigation(defaults: PopoverViewSnapshotTests.freshDefaults()).tab, .timer)
    }

    func testTheLastTabIsRemembered() {
        let defaults = PopoverViewSnapshotTests.freshDefaults()
        let navigation = PopoverNavigation(defaults: defaults)
        navigation.select(.stats)
        XCTAssertEqual(navigation.tab, .stats)
        XCTAssertEqual(PopoverNavigation(defaults: defaults).tab, .stats, "a new popover, or a relaunch, reopens it")

        navigation.select(.sounds)
        XCTAssertEqual(PopoverNavigation(defaults: defaults).tab, .sounds)
    }

    func testAnUnknownStoredTabFallsBackToTimer() {
        let defaults = PopoverViewSnapshotTests.freshDefaults()
        defaults.set("calendar", forKey: PopoverNavigation.tabKey)
        XCTAssertEqual(PopoverNavigation(defaults: defaults).tab, .timer)
    }

    func testQuickAddSwitchesToTasksAndRequestsFocus() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let defaults = PopoverViewSnapshotTests.freshDefaults()
        let navigation = PopoverNavigation(defaults: defaults)
        for tab in PopoverTab.allCases {
            navigation.select(tab)
            model.quickAddFocusTaken()

            navigation.showQuickAdd(in: model)
            XCTAssertEqual(navigation.tab, .tasks, "from \(tab)")
            XCTAssertTrue(model.wantsQuickAddFocus, "from \(tab)")
        }
        XCTAssertEqual(PopoverNavigation(defaults: defaults).tab, .tasks)
    }

    /// The popover's chrome reads `stage`, so it must not change with the seconds.
    func testStageChangesWithStatusButNotTicks() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        model.setPopoverVisible(true)
        model.startFocus()
        let before = model.snapshot

        let invalidated = Flag()
        withObservationTracking { _ = model.stage } onChange: { invalidated.set() }
        h.scheduler.advance(by: 5)
        XCTAssertNotEqual(model.snapshot, before, "the readout ticked")
        XCTAssertFalse(invalidated.isSet)

        model.pause()
        XCTAssertTrue(invalidated.isSet)
        XCTAssertEqual(model.stage.status, .paused)
    }

    func testOpenStatsShowsThePlannerOnItsStatsTab() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let router = WindowRouter(model: model, launchAtLogin: LaunchAtLogin(service: FakeLoginItem(), model: model))
        defer { NSApp.windows.filter { $0.title == "Planner" }.forEach { $0.close() } }

        router.show(.stats)
        XCTAssertEqual(router.plannerRoute.tab, .stats)
        router.show(.planner)
        XCTAssertEqual(router.plannerRoute.tab, .plan)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
