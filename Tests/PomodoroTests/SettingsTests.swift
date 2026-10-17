import KeyboardShortcuts
import PomodoroCore
import ServiceManagement
import XCTest
@testable import Pomodoro

@MainActor
final class FakeLoginItem: LoginItemService {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    var status: LoginItemStatus
    /// What registering leads to: `.enabled`, or `.requiresApproval` when the user must allow it.
    var statusAfterRegister: LoginItemStatus = .enabled
    var fails = false
    private(set) var openedSystemSettings = 0

    init(_ status: LoginItemStatus = .disabled) {
        self.status = status
    }

    func register() throws {
        if fails { throw Failure() }
        status = statusAfterRegister
    }

    func unregister() throws {
        if fails { throw Failure() }
        status = .disabled
    }

    func openSystemSettings() {
        openedSystemSettings += 1
    }
}

/// Behaves like a store whose data was written by a newer build.
final class NewerVersionSettingsStore: SettingsStore, @unchecked Sendable {
    var rejectsSaves = true

    func load() -> AppSettings { .default }

    func save(_ settings: AppSettings) throws {
        if rejectsSaves { throw SettingsStoreError.newerVersionStored(AppSettings.currentVersion + 1) }
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    // MARK: Timer tab

    func testTimerEditsReachTheStoreAndTheEngine() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        var configurations: [TimerConfiguration] = []
        model.onEngineUpdate = { engine, _ in configurations.append(engine.configuration) }

        model.defaultProfileBinding(\.focusDuration).minutes.wrappedValue = 40
        model.defaultProfileBinding(\.longBreakEvery).wrappedValue = 3
        model.defaultProfileBinding(\.autoStartBreaks).wrappedValue = true

        XCTAssertEqual(configurations.count, 3)
        XCTAssertEqual(configurations.last?.focusDuration, 40 * 60)
        XCTAssertEqual(configurations.last?.longBreakEvery, 3)
        XCTAssertEqual(configurations.last?.autoStartBreaks, true)
        let stored = h.settingsStore.load()
        XCTAssertEqual(stored.defaultPresetID, Preset.classic.id)
        XCTAssertEqual(stored.defaultProfile.focusDuration, 40 * 60)
        XCTAssertEqual(stored.preset(id: Preset.deep.id), .deep, "only the default preset changes")

        XCTAssertEqual(model.nextFocusDuration, 40 * 60)
        model.startFocus()
        XCTAssertEqual(model.snapshot.plannedDuration, 40 * 60)
    }

    func testTurningNudgesOffReschedulesARunningOvertime() throws {
        let h = try ModelHarness(display: .iconOnly)
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: 25 * 60 + 30)
        XCTAssertEqual(h.scheduler.pendingDates, [ModelHarness.start + 25 * 60 + TimerProfile.defaultNudgeInterval])

        model.defaultProfileBinding(\.nudgeInterval).wrappedValue = nil
        XCTAssertEqual(h.scheduler.pendingDates, [], "no nudge left to wait for")
        XCTAssertNil(h.settingsStore.load().defaultProfile.nudgeInterval)
    }

    func testMinutesBindingRoundsAndClamps() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let focus = model.defaultProfileBinding(\.focusDuration)
        focus.minutes.wrappedValue = 500
        XCTAssertEqual(focus.wrappedValue, TimerProfile.durationRange.upperBound)
        focus.wrappedValue = 89.6
        XCTAssertEqual(focus.minutes.wrappedValue, 1)
    }

    func testTypedMinutesCommitOnceOnReturn() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let idle = h.scheduler.scheduledCount
        model.startFocus()
        // One pass through the model reschedules the boundary and the display refresh.
        let perPass = h.scheduler.scheduledCount - idle
        var updates = 0
        model.onEngineUpdate = { _, _ in updates += 1 }
        let scheduled = h.scheduler.scheduledCount
        let minutes = model.defaultProfileBinding(\.shortBreakDuration).minutes
        var draft = MinutesDraft(range: MinutesField.defaultRange)

        draft.text = "4"
        draft.text = "45"
        XCTAssertEqual(updates, 0, "typing alone saves nothing")
        XCTAssertEqual(h.scheduler.scheduledCount, scheduled, "typing alone reschedules nothing")
        XCTAssertEqual(draft.displayed(minutes.wrappedValue), "45")

        draft.commit(to: minutes)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(h.scheduler.scheduledCount, scheduled + perPass, "rescheduled once")
        XCTAssertEqual(h.settingsStore.load().defaultProfile.shortBreakDuration, 45 * 60)
        XCTAssertEqual(draft.displayed(minutes.wrappedValue), "45")

        draft.commit(to: minutes)
        XCTAssertEqual(updates, 1, "a second commit with nothing typed writes nothing")
    }

    func testTypedMinutesClampWhenCommitted() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let minutes = model.defaultProfileBinding(\.focusDuration).minutes
        var draft = MinutesDraft(range: MinutesField.defaultRange)

        draft.text = "0"
        XCTAssertEqual(draft.displayed(minutes.wrappedValue), "0", "not corrected while typing")
        draft.commit(to: minutes)
        XCTAssertEqual(minutes.wrappedValue, 1)
        XCTAssertEqual(draft.displayed(minutes.wrappedValue), "1")

        draft.text = "999"
        draft.commit(to: minutes)
        XCTAssertEqual(minutes.wrappedValue, 180)
        XCTAssertEqual(draft.displayed(minutes.wrappedValue), "180")

        draft.text = ""
        draft.commit(to: minutes)
        XCTAssertEqual(minutes.wrappedValue, 180, "empty text reverts")
        XCTAssertEqual(draft.displayed(minutes.wrappedValue), "180")
    }

    func testSteppingStartsFromTheTypedValue() {
        var draft = MinutesDraft(range: 1...180, text: "40")
        XCTAssertEqual(draft.value(25), 40)
        draft.text = "abc"
        XCTAssertEqual(draft.value(25), 25)
    }

    // MARK: Presets tab

    func testMakeDefaultSwitchesTheEngineAndWhatTheTimerTabEdits() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        var configurations: [TimerConfiguration] = []
        model.onEngineUpdate = { engine, _ in configurations.append(engine.configuration) }

        model.updateSettings { try? $0.setDefaultPreset(id: Preset.deep.id) }
        XCTAssertEqual(configurations.last?.focusDuration, 50 * 60)
        XCTAssertEqual(h.settingsStore.load().defaultPresetID, Preset.deep.id)
        XCTAssertEqual(model.nextFocusDuration, 50 * 60)

        model.defaultProfileBinding(\.focusDuration).minutes.wrappedValue = 45
        XCTAssertEqual(model.settings.preset(id: Preset.deep.id)?.profile.focusDuration, 45 * 60)
        XCTAssertEqual(model.settings.preset(id: Preset.classic.id), .classic)
    }

    func testMakeDefaultDuringFocusAppliesFromTheNextSessionOn() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        model.updateSettings { try? $0.setDefaultPreset(id: Preset.quick.id) }
        XCTAssertEqual(model.snapshot.plannedDuration, 25 * 60, "the running focus keeps its length")
        model.stopAndLog()
        model.startFocus()
        XCTAssertEqual(model.snapshot.plannedDuration, 15 * 60)
    }

    // MARK: Sounds and menu bar tabs

    func testSoundEditsReachTheSoundService() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.binding(\.sounds.volume).wrappedValue = 0.3
        model.binding(SoundEvent.focusEnd.settingsPath).wrappedValue = .bowl
        XCTAssertEqual(model.sound.settings.volume, 0.3)
        XCTAssertEqual(model.sound.settings.focusEnd, .bowl)
        XCTAssertEqual(h.settingsStore.load().sounds.focusEnd, .bowl)
    }

    func testMenuBarPreviewMatchesTheRealTitle() {
        XCTAssertNil(MenuBarTitle.text(for: MenuBarPreview.sample, mode: .iconOnly))
        XCTAssertEqual(MenuBarTitle.text(for: MenuBarPreview.sample, mode: .time), "🍅 18:42")
        XCTAssertEqual(
            MenuBarTitle.text(for: MenuBarPreview.sample, mode: .timeAndTask, taskTitle: MenuBarPreview.sampleTask),
            "🍅 18:42 · Write the spec")
    }

    // MARK: Save errors

    func testNewerStoredVersionIsSurfacedAndEditsStillApply() throws {
        let h = try ModelHarness()
        let store = NewerVersionSettingsStore()
        let model = AppModel(
            clock: h.clock, settingsStore: store, timerStore: h.timerStore, database: h.database,
            sound: SoundService(players: [:]), scheduler: h.scheduler)
        XCTAssertNil(model.settingsSaveError)

        model.updateSettings { $0.menuBarDisplay = .iconOnly }
        XCTAssertEqual(model.settingsSaveError, .newerVersionStored(AppSettings.currentVersion + 1))
        XCTAssertEqual(model.settings.menuBarDisplay, .iconOnly)

        model.dismissSettingsSaveError()
        XCTAssertNil(model.settingsSaveError)

        model.updateSettings { $0.menuBarDisplay = .time }
        XCTAssertNotNil(model.settingsSaveError)
        store.rejectsSaves = false
        model.updateSettings { $0.menuBarDisplay = .timeAndTask }
        XCTAssertNil(model.settingsSaveError, "a later successful save clears it")
    }

    // MARK: Launch at login

    func testLoginItemStatusMapping() {
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.enabled), .enabled)
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.notRegistered), .disabled)
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemStatus(SMAppService.Status.notFound), .notFound)
        XCTAssertTrue(LoginItemStatus.enabled.isRegistered)
        XCTAssertTrue(LoginItemStatus.requiresApproval.isRegistered)
        XCTAssertFalse(LoginItemStatus.disabled.isRegistered)
        XCTAssertFalse(LoginItemStatus.notFound.isRegistered)
    }

    func testLaunchAtLoginFollowsTheSystemNotTheStoredFlag() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.updateSettings { $0.launchAtLogin = true }
        let service = FakeLoginItem(.disabled)
        let launch = LaunchAtLogin(service: service, model: model)
        XCTAssertFalse(launch.isOn)
        XCTAssertFalse(model.settings.launchAtLogin, "a stale stored flag gives way to the real status")

        launch.setEnabled(true)
        XCTAssertEqual(launch.status, .enabled)
        XCTAssertTrue(h.settingsStore.load().launchAtLogin)

        // Removed in System Settings while the app runs.
        service.status = .disabled
        launch.refresh()
        XCTAssertFalse(launch.isOn)
        XCTAssertFalse(model.settings.launchAtLogin)
    }

    func testLaunchAtLoginAwaitingApproval() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let service = FakeLoginItem(.disabled)
        service.statusAfterRegister = .requiresApproval
        let launch = LaunchAtLogin(service: service, model: model)

        launch.setEnabled(true)
        XCTAssertEqual(launch.status, .requiresApproval)
        XCTAssertTrue(launch.isOn, "the toggle stays on while approval is pending")
        XCTAssertTrue(model.settings.launchAtLogin)
        launch.openSystemSettings()
        XCTAssertEqual(service.openedSystemSettings, 1)

        launch.setEnabled(false)
        XCTAssertEqual(launch.status, .disabled)
        XCTAssertFalse(model.settings.launchAtLogin)
    }

    func testLaunchAtLoginFailureKeepsTheRealStatus() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let service = FakeLoginItem(.disabled)
        service.fails = true
        let launch = LaunchAtLogin(service: service, model: model)

        launch.setEnabled(true)
        XCTAssertEqual(launch.status, .disabled)
        XCTAssertEqual(launch.errorMessage, "Operation not permitted")
        service.fails = false
        launch.setEnabled(true)
        XCTAssertNil(launch.errorMessage)
        XCTAssertTrue(launch.isOn)
    }

    // MARK: Hotkeys

    func testHotkeysHaveUniqueNamesAndNoDefaults() {
        let names = Hotkey.allCases.map(\.name)
        XCTAssertEqual(Set(names.map(\.rawValue)).count, Hotkey.allCases.count)
        for name in names {
            XCTAssertNil(name.initialShortcut, "\(name.rawValue) must not claim a shortcut by default")
        }
    }

    func testHotkeyActionsRouteToTheModelAndPopover() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        var popoverToggles = 0
        var quickAdds = 0
        let actions = HotkeyActions(
            toggleTimer: { model.toggle() },
            skipPhase: { model.skip() },
            togglePopover: { popoverToggles += 1 },
            quickAdd: { quickAdds += 1 }
        )

        actions.perform(.toggleTimer)
        XCTAssertEqual(model.snapshot.phase, .focus)
        actions.perform(.toggleTimer)
        XCTAssertEqual(model.snapshot.status, .paused)
        actions.perform(.skipPhase)
        XCTAssertEqual(model.snapshot.phase, .shortBreak)
        actions.perform(.openPopover)
        actions.perform(.quickAdd)
        XCTAssertEqual(popoverToggles, 1)
        XCTAssertEqual(quickAdds, 1)
    }

    /// Whichever tab was left showing, the hotkey brings the field's tab forward.
    func testQuickAddHotkeyOpensThePopoverAndRequestsFieldFocus() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let windows = WindowRouter(model: model, launchAtLogin: LaunchAtLogin(service: FakeLoginItem(), model: model))
        let menuBar = MenuBarController(model: model, windows: windows, defaults: PopoverViewSnapshotTests.freshDefaults())
        defer { if model.isPopoverVisible { menuBar.togglePopover(nil) } }
        menuBar.navigation.select(.stats)
        XCTAssertFalse(model.wantsQuickAddFocus)

        menuBar.focusQuickAdd()
        XCTAssertTrue(model.wantsQuickAddFocus)
        XCTAssertEqual(menuBar.navigation.tab, .tasks)

        model.quickAddFocusTaken()
        XCTAssertFalse(model.wantsQuickAddFocus)
    }

    func testAnUntakenQuickAddRequestEndsWithThePopover() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.setPopoverVisible(true)
        model.requestQuickAddFocus()
        model.setPopoverVisible(false)
        XCTAssertFalse(model.wantsQuickAddFocus)
    }

    // MARK: Window

    func testSettingsWindowHasAToolbarTabPerPane() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        let window = SettingsWindow.make(model: model, launchAtLogin: LaunchAtLogin(service: FakeLoginItem(), model: model))
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), SettingsPane.allCases.map(\.title))
        XCTAssertTrue(tabs.tabViewItems.allSatisfy { $0.image != nil }, "every tab has its symbol")
    }

    // MARK: Pending drafts

    /// The real Settings window, shown, with the model's updates counted.
    private func openSettings() throws -> (ModelHarness, AppModel, NSWindow, NSTabViewController, () -> Int) {
        let h = try ModelHarness()
        let model = h.makeModel()
        var updates = 0
        model.onEngineUpdate = { _, _ in updates += 1 }
        let window = SettingsWindow.make(model: model, launchAtLogin: LaunchAtLogin(service: FakeLoginItem(), model: model))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        spin()
        return (h, model, window, tabs, { updates })
    }

    private func spin() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return own + view.subviews.flatMap(editableFields)
    }

    /// Types into the Timer tab's Focus field without pressing Return or moving focus.
    private func typeFocusMinutes(_ text: String, in window: NSWindow, tabs: NSTabViewController) throws -> NSTextField {
        let pane = try XCTUnwrap(tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view)
        let field = try XCTUnwrap(editableFields(in: pane).first, "the Focus minutes field")
        XCTAssertEqual(field.stringValue, "25")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        spin()
        return field
    }

    func testClosingSettingsCommitsTheTypedMinutesOnce() throws {
        let (h, model, window, tabs, updates) = try openSettings()
        _ = try typeFocusMinutes("999", in: window, tabs: tabs)
        XCTAssertEqual(updates(), 0, "typing alone saves nothing")

        window.performClose(nil)
        XCTAssertEqual(updates(), 1, "committed before close returns")
        XCTAssertEqual(model.settings.defaultProfile.focusDuration, 180 * 60, "clamped")
        XCTAssertEqual(h.settingsStore.load().defaultProfile.focusDuration, 180 * 60)
        spin()
        XCTAssertEqual(updates(), 1, "the later focus loss writes nothing more")

        window.makeKeyAndOrderFront(nil)
        spin()
        window.performClose(nil)
        spin()
        XCTAssertEqual(updates(), 1, "reopening and closing again saves nothing")
    }

    func testSwitchingTabsCommitsTheTypedMinutesToTheOriginalDefaultOnce() throws {
        let (h, model, window, tabs, updates) = try openSettings()
        defer { window.close() }
        let field = try typeFocusMinutes("40", in: window, tabs: tabs)

        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: .presets)!
        XCTAssertEqual(updates(), 1)
        XCTAssertEqual(h.settingsStore.load().defaultProfile.focusDuration, 40 * 60)
        spin()
        XCTAssertEqual(updates(), 1)

        model.updateSettings { try? $0.setDefaultPreset(id: Preset.deep.id) }
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: .timer)!
        spin()
        XCTAssertEqual(updates(), 2, "only the default change")
        XCTAssertEqual(model.settings.preset(id: Preset.classic.id)?.profile.focusDuration, 40 * 60)
        XCTAssertEqual(model.settings.preset(id: Preset.deep.id), .deep)
        XCTAssertEqual(field.stringValue, "50", "shows the new default, not the old draft")
    }

    func testResigningActiveCommitsTheTypedMinutes() throws {
        let (h, _, window, tabs, updates) = try openSettings()
        defer { window.close() }
        _ = try typeFocusMinutes("30", in: window, tabs: tabs)
        NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        XCTAssertEqual(updates(), 1)
        XCTAssertEqual(h.settingsStore.load().defaultProfile.focusDuration, 30 * 60)
    }
}
