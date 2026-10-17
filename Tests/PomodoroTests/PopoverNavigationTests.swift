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

    /// The draft lives on the navigation, not in the field the Tasks tab tears down.
    func testTheQuickAddDraftSurvivesATabRoundTrip() {
        let navigation = PopoverNavigation(defaults: PopoverViewSnapshotTests.freshDefaults())
        navigation.select(.tasks)
        navigation.quickAddDraft = "Write spec ~2"
        navigation.isEditingTask = true
        XCTAssertFalse(navigation.spaceTogglesTimer, "Space types into the field")

        navigation.select(.timer)
        XCTAssertTrue(navigation.spaceTogglesTimer, "the field left with its tab, so Space toggles again")
        XCTAssertFalse(navigation.isEditingTask)

        navigation.select(.tasks)
        XCTAssertEqual(navigation.quickAddDraft, "Write spec ~2")
        XCTAssertTrue(navigation.spaceTogglesTimer, "the field comes back unfocused")
    }

    /// With no Dock icon, the ⚙ menu is the visible way to quit.
    func testTheGearMenuOffersSettingsAndQuit() {
        var calls: [String] = []
        let menu = PopoverGearMenu.make(PopoverActions(
            openSettings: { calls.append("settings") },
            quit: { calls.append("quit") }
        ))
        let items = menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.map(\.title), ["Settings…", "Quit Pomodoro"])
        XCTAssertEqual(items.map(\.keyEquivalent), [",", "q"])
        XCTAssertEqual(items.map(\.keyEquivalentModifierMask), [.command, .command])
        XCTAssertTrue(items.allSatisfy(\.isEnabled))

        menu.performActionForItem(at: menu.index(of: items[0]))
        XCTAssertEqual(calls, ["settings"])
        menu.performActionForItem(at: menu.index(of: items[1]))
        XCTAssertEqual(calls, ["settings", "quit"])
    }

    /// Every stage change re-renders the chrome; nothing in between does.
    func testStageChangesAtEachTransitionButNotBetween() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        model.setPopoverVisible(true)
        let focus: TimeInterval = 25 * 60
        let cycle = model.stage.completedFocusesInCycle

        func changes(_ step: () -> Void) -> Bool {
            let invalidated = Flag()
            withObservationTracking { _ = model.stage } onChange: { invalidated.set() }
            step()
            return invalidated.isSet
        }

        XCTAssertTrue(changes { model.startFocus() }, "start")
        XCTAssertFalse(changes { h.scheduler.advance(by: 60) }, "focus ticking")
        XCTAssertTrue(changes { h.scheduler.advance(by: focus) }, "into overtime")
        XCTAssertTrue(model.stage.isOvertime)
        XCTAssertFalse(changes { h.scheduler.advance(by: 30) }, "overtime ticking")
        XCTAssertTrue(changes { model.pause() }, "pause in overtime")
        XCTAssertFalse(changes { h.clock.advance(by: 30); model.reconcile() }, "paused overtime")
        XCTAssertTrue(changes { model.resume() }, "resume overtime")
        XCTAssertTrue(changes { model.extend(minutes: 5) }, "extension")
        XCTAssertFalse(model.stage.isOvertime)
        XCTAssertFalse(changes { h.scheduler.advance(by: 60) }, "extension ticking")
        XCTAssertTrue(changes { h.scheduler.advance(by: 5 * 60) }, "extension over")
        XCTAssertTrue(changes { model.startBreak() }, "break")
        XCTAssertTrue(model.stage.phase.isBreak)
        XCTAssertNotEqual(model.stage.completedFocusesInCycle, cycle, "a finished focus counts toward the cycle")
        XCTAssertFalse(changes { h.scheduler.advance(by: 60) }, "break ticking")
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
