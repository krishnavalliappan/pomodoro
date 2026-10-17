import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
final class AppModelTests: XCTestCase {
    private let focus: TimeInterval = 25 * 60

    // MARK: Scheduling

    func testIconOnlyWithPopoverClosedSchedulesOnlyBoundaries() throws {
        let h = try ModelHarness(display: .iconOnly)
        let model = h.makeModel()
        XCTAssertEqual(h.scheduler.pendingDates, [], "idle schedules nothing")

        model.startFocus()
        XCTAssertFalse(model.isRefreshingEverySecond)
        XCTAssertEqual(h.scheduler.pendingDates, [ModelHarness.start + focus])

        h.scheduler.advance(by: focus + 90)
        XCTAssertEqual(h.scheduler.firedCount, 1, "only the phase end fired in 26.5 minutes")
        XCTAssertEqual(model.snapshot.status, .overtime(since: ModelHarness.start + focus))
        XCTAssertFalse(model.isRefreshingEverySecond)
        // Overtime waits for the next nudge, not for the next second.
        XCTAssertEqual(h.scheduler.pendingDates, [ModelHarness.start + focus + TimerProfile.defaultNudgeInterval])
    }

    func testOpenPopoverRefreshesOnEachSecondAndStopsOnClose() throws {
        let h = try ModelHarness(display: .iconOnly)
        let model = h.makeModel()
        model.startFocus()
        model.setPopoverVisible(true)
        XCTAssertTrue(model.isRefreshingEverySecond)

        h.scheduler.advance(by: 10)
        XCTAssertEqual(h.scheduler.firedCount, 9, "one refresh per digit flip, landing just after it")
        XCTAssertEqual(TimerReadout(model.snapshot).text, "24:51")

        model.setPopoverVisible(false)
        XCTAssertFalse(model.isRefreshingEverySecond)
        XCTAssertEqual(h.scheduler.pendingDates, [ModelHarness.start + focus])
    }

    func testTimeInMenuBarRefreshesWithPopoverClosed() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        model.startFocus()
        XCTAssertTrue(model.isRefreshingEverySecond)
        h.scheduler.advance(by: 6 * 60 + 18.5)
        XCTAssertEqual(model.statusTitle, "🍅 18:42")
    }

    func testPausedNeedsNoTimersAtAll() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        model.startFocus()
        model.setPopoverVisible(true)
        model.pause()
        XCTAssertFalse(model.isRefreshingEverySecond)
        XCTAssertEqual(h.scheduler.pendingDates, [])
        model.resume()
        XCTAssertTrue(model.isRefreshingEverySecond)
    }

    func testSwitchingDisplayModeStartsAndStopsRefresh() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        model.startFocus()
        model.updateSettings { $0.menuBarDisplay = .iconOnly }
        XCTAssertFalse(model.isRefreshingEverySecond)
        XCTAssertEqual(h.settingsStore.load().menuBarDisplay, .iconOnly)
        model.updateSettings { $0.menuBarDisplay = .timeAndTask }
        XCTAssertTrue(model.isRefreshingEverySecond)
    }

    func testReconcileCatchesUpAfterAMissedBoundary() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        // As across a system sleep: time passes but no timer fires.
        h.clock.advance(by: focus + 120)
        model.reconcile()
        XCTAssertEqual(model.snapshot.status, .overtime(since: ModelHarness.start + focus))
        XCTAssertEqual(model.statusTitle, "+02:00")
        XCTAssertEqual(model.prompt, .focusEnded)
    }

    // MARK: Status title

    func testStatusTitleFollowsDisplayMode() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        XCTAssertNil(model.statusTitle, "idle shows the icon")
        model.startFocus()
        XCTAssertEqual(model.statusTitle, "🍅 25:00")
        model.updateSettings { $0.menuBarDisplay = .timeAndTask }
        XCTAssertEqual(model.statusTitle, "🍅 25:00", "no task until #10")
        model.updateSettings { $0.menuBarDisplay = .iconOnly }
        XCTAssertNil(model.statusTitle)
    }

    // MARK: Logging

    func testCompletedFocusIsLogged() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        XCTAssertEqual(model.completedToday, 0)
        model.startFocus()
        h.scheduler.advance(by: focus + 60)
        model.startBreak()

        let sessions = try h.sessionsToday()
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertTrue(session.completed)
        XCTAssertEqual(session.start, ModelHarness.start)
        XCTAssertEqual(session.plannedSeconds, focus)
        XCTAssertEqual(session.activeSeconds, focus + 60, accuracy: 0.001)
        XCTAssertEqual(session.overtimeSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(session.pausedSeconds, 0)
        XCTAssertEqual(model.completedToday, 1)
        XCTAssertEqual(model.snapshot.phase, .shortBreak)
    }

    func testStoppedFocusIsLoggedAsIncomplete() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: 300)
        model.pause()
        h.scheduler.advance(by: 60)
        model.resume()
        h.scheduler.advance(by: 300)
        model.stopAndLog()

        let session = try XCTUnwrap(try h.sessionsToday().first)
        XCTAssertFalse(session.completed)
        XCTAssertEqual(session.activeSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(session.pausedSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(model.completedToday, 0)
        XCTAssertEqual(model.snapshot.phase, .idle)
    }

    func testCompletedTodayCountsEarlierSessions() throws {
        let h = try ModelHarness()
        try h.seedCompletedSessions(3)
        XCTAssertEqual(h.makeModel().completedToday, 3)
    }

    // MARK: Profiles and overrides

    func testOneOffOverrideCoversOneFocusAndItsBreak() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        XCTAssertFalse(model.applyOverride("fifty"))
        XCTAssertTrue(model.applyOverride("50/10"))
        XCTAssertEqual(model.nextFocusDuration, 50 * 60)

        model.startFocus()
        XCTAssertNil(model.pendingOverride)
        XCTAssertEqual(model.snapshot.plannedDuration, 50 * 60)
        model.skip()
        XCTAssertEqual(model.snapshot.phase, .shortBreak)
        XCTAssertEqual(model.snapshot.plannedDuration, 10 * 60)
        model.skip()
        XCTAssertEqual(model.snapshot.phase, .focus)
        XCTAssertEqual(model.snapshot.plannedDuration, focus, "the default is back")
        XCTAssertEqual(h.settingsStore.load().defaultPresetID, Preset.classic.id, "defaults untouched")
    }

    func testPresetChipIsAOneOffAndNeverTheDefault() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.applyOverride("40")
        model.toggleOneOffPreset(Preset.deep.id)
        XCTAssertEqual(model.pendingOneOff, .preset(Preset.deep.id), "replaces the typed one-off")
        XCTAssertEqual(model.nextFocusDuration, 50 * 60)

        model.startFocus()
        XCTAssertEqual(model.snapshot.plannedDuration, 50 * 60)
        model.skip()
        XCTAssertEqual(model.snapshot.plannedDuration, 10 * 60)
        model.skip()
        XCTAssertEqual(model.snapshot.plannedDuration, focus)
        XCTAssertEqual(h.settingsStore.load().defaultPresetID, Preset.classic.id)
        XCTAssertEqual(model.settings.defaultPresetID, Preset.classic.id)
    }

    func testTappingAPresetChipAgainOrTheDefaultClearsIt() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.toggleOneOffPreset(Preset.quick.id)
        model.toggleOneOffPreset(Preset.quick.id)
        XCTAssertNil(model.pendingOneOff)
        model.toggleOneOffPreset(Preset.quick.id)
        model.toggleOneOffPreset(Preset.classic.id)
        XCTAssertNil(model.pendingOneOff, "the default's chip means no one-off")
        model.applyOverride("40")
        model.clearOneOff()
        XCTAssertNil(model.pendingOneOff)
    }

    func testOneOffQueuedDuringABreakIsTakenBySkip() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        model.startBreak()
        XCTAssertTrue(model.applyOverride("40/8"))
        model.skip()
        XCTAssertEqual(model.snapshot.phase, .focus)
        XCTAssertEqual(model.snapshot.plannedDuration, 40 * 60)
        XCTAssertNil(model.pendingOneOff)
        model.skip()
        XCTAssertEqual(model.snapshot.plannedDuration, 8 * 60, "its break follows")
        model.skip()
        XCTAssertEqual(model.snapshot.plannedDuration, focus, "and the next focus is back on the default")
    }

    func testSkippingTheOneOffFocusKeepsItsBreak() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.applyOverride("50/10")
        model.startFocus()
        h.scheduler.advance(by: 60)
        model.skip()
        XCTAssertEqual(model.snapshot.phase, .shortBreak)
        XCTAssertEqual(model.snapshot.plannedDuration, 10 * 60)
    }

    func testOneOffQueuedDuringABreakIsTakenByAutoStart() throws {
        let h = try ModelHarness()
        h.updateDefaultProfile { $0.autoStartFocus = true }
        let model = h.makeModel()
        model.startFocus()
        model.startBreak()
        model.applyOverride("40/8")
        h.scheduler.advance(by: 5 * 60)
        XCTAssertEqual(model.snapshot.phase, .focus)
        XCTAssertEqual(model.snapshot.plannedDuration, 40 * 60)
        XCTAssertNil(model.pendingOneOff)
        h.scheduler.advance(by: 40 * 60)
        model.startBreak()
        XCTAssertEqual(model.snapshot.plannedDuration, 8 * 60, "its break follows")
        model.skip()
        XCTAssertEqual(model.snapshot.phase, .focus)
        XCTAssertEqual(model.snapshot.plannedDuration, focus, "and the next focus is back on the default")
    }

    func testOneOffChainsThroughAutoStartsAndStopsAtTheNextFocus() throws {
        let h = try ModelHarness(display: .iconOnly)
        h.updateDefaultProfile {
            $0.autoStartBreaks = true
            $0.autoStartFocus = true
        }
        let model = h.makeModel()
        model.applyOverride("50/10")
        model.startFocus()
        h.scheduler.advance(by: 50 * 60)
        XCTAssertEqual(model.snapshot.phase, .shortBreak)
        XCTAssertEqual(model.snapshot.plannedDuration, 10 * 60, "auto break")
        h.scheduler.advance(by: 10 * 60)
        XCTAssertEqual(model.snapshot.phase, .focus)
        XCTAssertEqual(model.snapshot.plannedDuration, focus, "auto focus is back on the default")
        h.scheduler.advance(by: focus)
        XCTAssertEqual(model.snapshot.plannedDuration, 5 * 60, "and so is its break")
    }

    func testOneOffDoesNotLeakIntoAFocusChainedInOneReconcile() throws {
        let h = try ModelHarness(display: .iconOnly)
        h.updateDefaultProfile {
            $0.autoStartBreaks = true
            $0.autoStartFocus = true
        }
        var model: AppModel? = h.makeModel()
        model?.applyOverride("50/10")
        model?.startFocus()
        model?.shutdown()
        model = nil
        // Relaunch at minute 60: the one-off focus and its break both ended while quit.
        h.clock.advance(by: 60 * 60)

        let relaunched = h.makeModel()
        XCTAssertEqual(relaunched.snapshot.phase, .focus)
        XCTAssertEqual(relaunched.snapshot.plannedDuration, focus)
        XCTAssertNil(try XCTUnwrap(h.timerStore.load()).profile, "persisted as a default session")
        h.scheduler.advance(by: focus)
        XCTAssertEqual(relaunched.snapshot.phase, .shortBreak)
        XCTAssertEqual(relaunched.snapshot.plannedDuration, 5 * 60)
    }

    // MARK: Prompts

    func testOvertimePromptAndItsChoices() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus + 30)
        XCTAssertEqual(model.prompt, .focusEnded)

        model.keepGoing()
        XCTAssertNil(model.prompt, "keep going dismisses the prompt")
        XCTAssertEqual(model.statusTitle, "+00:30")

        model.extend(minutes: 5)
        XCTAssertEqual(model.snapshot.status, .running)
        XCTAssertEqual(model.statusTitle, "🍅 05:00")
        h.scheduler.advance(by: 5 * 60)
        XCTAssertEqual(model.prompt, .focusEnded, "the extension ends with a fresh prompt")

        model.startBreak()
        XCTAssertNil(model.prompt)
        h.scheduler.advance(by: 5 * 60 + 1)
        XCTAssertEqual(model.prompt, .breakEnded)
        model.stopAndLog()
        XCTAssertEqual(model.snapshot.phase, .idle)
        XCTAssertNil(model.prompt)
    }

    func testSpaceToggles() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.toggle()
        XCTAssertEqual(model.snapshot.status, .running)
        model.toggle()
        XCTAssertEqual(model.snapshot.status, .paused)
        model.toggle()
        XCTAssertEqual(model.snapshot.status, .running)
    }

    // MARK: Sounds

    func testSoundsFollowEngineEvents() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        XCTAssertEqual(h.plays(.start), 1)
        h.scheduler.advance(by: focus)
        XCTAssertEqual(h.plays(.chimeFocusEnd), 1)
        model.startBreak()
        XCTAssertEqual(h.plays(.start), 2)
        h.scheduler.advance(by: 5 * 60)
        XCTAssertEqual(h.plays(.chimeBreakEnd), 1)
        model.pause()
        XCTAssertEqual(h.plays(.start) + h.plays(.chimeFocusEnd) + h.plays(.chimeBreakEnd), 4, "pause is silent")
    }

    func testOneSoundPerBatch() {
        XCTAssertEqual(AppModel.sound(for: [.focusEnded, .phaseStarted(.shortBreak)], phase: .shortBreak), .focusEnd)
        XCTAssertEqual(AppModel.sound(for: [.breakEnded, .phaseStarted(.focus)], phase: .focus), .breakEnd)
        XCTAssertEqual(AppModel.sound(for: [.phaseStarted(.focus)], phase: .focus), .start)
        XCTAssertEqual(AppModel.sound(for: [.nudge(overtime: 600)], phase: .focus), .focusEnd)
        XCTAssertEqual(AppModel.sound(for: [.nudge(overtime: 600)], phase: .longBreak), .breakEnd)
        XCTAssertNil(AppModel.sound(for: [], phase: .focus))
    }

    func testOvertimeNudgeReplaysTheEndChime() throws {
        let h = try ModelHarness(display: .iconOnly)
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: focus + TimerProfile.defaultNudgeInterval)
        XCTAssertEqual(h.plays(.chimeFocusEnd), 2, "the end, then one nudge")
    }

    // MARK: Relaunch

    func testRunningSessionSurvivesRelaunch() throws {
        let h = try ModelHarness()
        var model: AppModel? = h.makeModel()
        model?.applyOverride("50/10")
        model?.startFocus()
        h.scheduler.advance(by: 600)
        model = nil

        let relaunched = h.makeModel()
        XCTAssertEqual(relaunched.snapshot.phase, .focus)
        XCTAssertEqual(relaunched.snapshot.plannedDuration, 50 * 60)
        XCTAssertEqual(relaunched.snapshot.elapsed, 600, accuracy: 0.001)
        XCTAssertEqual(h.scheduler.pendingDates.last, ModelHarness.start + 50 * 60)
        relaunched.skip()
        XCTAssertEqual(relaunched.snapshot.plannedDuration, 10 * 60, "the override's break survives too")
    }

    func testSessionThatEndedWhileQuitIsReconciledOnLaunch() throws {
        let h = try ModelHarness()
        var model: AppModel? = h.makeModel()
        model?.startFocus()
        model = nil
        h.clock.advance(by: focus + 180)

        let relaunched = h.makeModel()
        XCTAssertEqual(relaunched.snapshot.status, .overtime(since: ModelHarness.start + focus))
        XCTAssertEqual(relaunched.prompt, .focusEnded)
        XCTAssertEqual(h.plays(.chimeFocusEnd), 1)
    }

    func testShutdownLeavesNoTimers() throws {
        let h = try ModelHarness(display: .time)
        let model = h.makeModel()
        model.startFocus()
        XCTAssertFalse(h.scheduler.pendingDates.isEmpty)
        model.shutdown()
        XCTAssertEqual(h.scheduler.pendingDates, [])
        XCTAssertFalse(model.isRefreshingEverySecond)
    }

    // MARK: Seams

    /// Records every `onEngineUpdate` call as the event kinds it carried.
    private final class UpdateLog {
        var batches: [[TimerEvent]] = []
        var phases: [TimerPhase] = []
    }

    private func observe(_ model: AppModel) -> UpdateLog {
        let log = UpdateLog()
        model.onEngineUpdate = { engine, events in
            log.batches.append(events)
            log.phases.append(engine.phase)
        }
        return log
    }

    func testEveryActionReachesTheUpdateHookEvenWithoutEvents() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let log = observe(model)
        model.startFocus()
        model.pause()
        h.scheduler.advance(by: 60)
        model.resume()
        model.extend(minutes: 5)
        XCTAssertEqual(log.batches, [[.phaseStarted(.focus)], [], [], []], "pause, resume and extend return no events")
        XCTAssertEqual(log.phases, [.focus, .focus, .focus, .focus])

        h.scheduler.advance(by: 30 * 60)
        XCTAssertEqual(log.batches.last, [.focusEnded], "the boundary reconcile")
        model.keepGoing()
        XCTAssertEqual(log.batches.last, [], "silencing nudges")
        model.startBreak()
        model.stopAndLog()
        XCTAssertEqual(log.batches.last, [], "stopping a break")
        XCTAssertEqual(log.phases.last, .idle)
    }

    func testSettingsChangesReachTheUpdateHook() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let log = observe(model)
        model.startFocus()
        model.updateSettings { _ = try? $0.updatePreset(Self.classic { $0.nudgeInterval = nil }) }
        XCTAssertEqual(log.batches.count, 2)
        XCTAssertEqual(log.batches.last, [])
        model.updateSettings { _ = $0 }
        XCTAssertEqual(log.batches.count, 2, "an unchanged setting isn't an update")
    }

    func testLaunchReconcileReachesAnUpdateHookPassedToInit() throws {
        let h = try ModelHarness()
        var model: AppModel? = h.makeModel()
        model?.startFocus()
        model?.shutdown()
        model = nil
        h.clock.advance(by: focus + 180)

        var batches: [[TimerEvent]] = []
        let relaunched = h.makeModel { _, events in batches.append(events) }
        XCTAssertEqual(batches, [[.focusEnded]], "the overdue end is announced once, at launch")
        XCTAssertEqual(relaunched.prompt, .focusEnded)
    }

    // MARK: Boundary rescheduling

    func testEnablingNudgesDuringBreakOvertimeSchedulesTheNextOne() throws {
        let h = try ModelHarness(display: .iconOnly)
        h.updateDefaultProfile { $0.nudgeInterval = nil }
        let model = h.makeModel()
        model.startFocus()
        model.startBreak()
        h.scheduler.advance(by: 5 * 60 + 30)
        XCTAssertEqual(model.snapshot.status, .overtime(since: ModelHarness.start + 5 * 60))
        XCTAssertEqual(h.scheduler.pendingDates, [], "no nudges, nothing to wait for")

        model.updateSettings { _ = try? $0.updatePreset(Self.classic { $0.nudgeInterval = 120 }) }
        XCTAssertEqual(h.scheduler.pendingDates, [ModelHarness.start + 5 * 60 + 120])
        h.scheduler.advance(by: 90)
        XCTAssertEqual(h.plays(.chimeBreakEnd), 2, "the end, then the new nudge")
    }

    func testChangingOrDisablingNudgesReschedules() throws {
        let h = try ModelHarness(display: .iconOnly)
        let model = h.makeModel()
        model.startFocus()
        model.startBreak()
        let end = ModelHarness.start + 5 * 60
        h.scheduler.advance(by: 5 * 60 + 30)
        XCTAssertEqual(h.scheduler.pendingDates, [end + TimerProfile.defaultNudgeInterval])

        model.updateSettings { _ = try? $0.updatePreset(Self.classic { $0.nudgeInterval = 180 }) }
        XCTAssertEqual(h.scheduler.pendingDates, [end + 180], "the old deadline is gone")

        model.updateSettings { _ = try? $0.updatePreset(Self.classic { $0.nudgeInterval = nil }) }
        XCTAssertEqual(h.scheduler.pendingDates, [])
    }

    private static func classic(_ change: (inout TimerProfile) -> Void) -> Preset {
        var preset = Preset.classic
        change(&preset.profile)
        return preset
    }
}
