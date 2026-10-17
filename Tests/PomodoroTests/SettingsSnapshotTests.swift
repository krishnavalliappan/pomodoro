import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testTimer() throws {
        assertPane(.timer, model: try ModelHarness().makeModel())
    }

    func testPresets() throws {
        let model = try ModelHarness().makeModel()
        model.updateSettings {
            $0.addPreset(name: "Sprint", profile: TimerProfile(focusDuration: 35 * 60, shortBreakDuration: 7 * 60, longBreakDuration: 20 * 60))
            try? $0.setDefaultPreset(id: Preset.deep.id)
        }
        assertPane(.presets, model: model)
    }

    func testSounds() throws {
        let model = try ModelHarness().makeModel()
        model.updateSettings { $0.sounds.tick = .tick }
        assertPane(.sounds, model: model)
    }

    func testMenuBar() throws {
        for mode in MenuBarDisplayMode.allCases {
            let model = try ModelHarness(display: mode).makeModel()
            assertPane(.menuBar, model: model, variant: "menuBar-\(mode.rawValue)")
        }
    }

    func testShortcuts() throws {
        assertPane(.shortcuts, model: try ModelHarness().makeModel())
    }

    func testGeneral() throws {
        assertPane(.general, model: try ModelHarness().makeModel())
    }

    func testGeneralAwaitingApproval() throws {
        assertPane(.general, model: try ModelHarness().makeModel(), login: FakeLoginItem(.requiresApproval), variant: "general-approval")
    }

    func testSaveErrorBanner() throws {
        let h = try ModelHarness()
        let model = AppModel(
            clock: h.clock, settingsStore: NewerVersionSettingsStore(), timerStore: h.timerStore, database: h.database,
            sound: SoundService(players: [:]), scheduler: h.scheduler)
        model.updateSettings { $0.menuBarDisplay = .timeAndTask }
        XCTAssertNotNil(model.settingsSaveError)
        assertPane(.menuBar, model: model, variant: "menuBar-saveError")
    }

    func testPresetEditor() {
        Snapshot.assertLightAndDark(
            PresetEditor(draft: PresetDraft(.deep), onCancel: {}, onSave: { _ in }),
            size: PresetEditor.size,
            name: "PresetEditor",
            variant: "edit"
        )
    }

    // MARK: - Helpers

    private func assertPane(
        _ pane: SettingsPane,
        model: AppModel,
        login: FakeLoginItem = FakeLoginItem(),
        variant: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        Snapshot.assertLightAndDark(
            SettingsPaneView(pane: pane, model: model, launchAtLogin: LaunchAtLogin(service: login, model: model)),
            size: pane.size,
            name: "SettingsView",
            variant: variant ?? pane.rawValue,
            inWindow: pane == .presets,
            file: file,
            line: line
        )
    }
}
