import Foundation
import Testing
@testable import PomodoroCore

struct AppSettingsTests {
    @Test func defaults() {
        let s = AppSettings.default
        #expect(s.presets == Preset.builtIns)
        #expect(s.presets.map(\.displayName) == ["Classic 25/5/15", "Deep 50/10/20", "Quick 15/3/10"])
        #expect(s.defaultPreset == .classic)
        #expect(s.defaultProfile == .classic)
        #expect(s.sounds == SoundSettings())
        #expect(s.sounds.focusEnd == .chimeFocusEnd)
        #expect(s.sounds.breakEnd == .chimeBreakEnd)
        #expect(s.sounds.start == .start)
        #expect(s.sounds.tick == SoundID.none)
        #expect(s.sounds.volume == 0.8)
        #expect(s.menuBarDisplay == .time)
        #expect(s.launchAtLogin == false)
        #expect(s.firstWeekday == nil)
    }

    @Test func soundIDCases() {
        #expect(SoundID.allCases.map(\.rawValue) == ["chimeFocusEnd", "chimeBreakEnd", "start", "tick", "bowl", "none"])
    }

    @Test func menuBarDisplayModes() {
        #expect(MenuBarDisplayMode.allCases.map(\.rawValue) == ["iconOnly", "time", "timeAndTask"])
    }

    @Test func codableRoundTrip() throws {
        var s = AppSettings.default
        let custom = s.addPreset(name: "Sprint", profile: TimerProfile(
            focusDuration: 35 * 60, shortBreakDuration: 4 * 60, longBreakDuration: 12 * 60, nudgeInterval: nil))
        try s.setDefaultPreset(id: custom.id)
        s.sounds = SoundSettings(focusEnd: .bowl, breakEnd: .none, start: .none, tick: .tick, volume: 0.25)
        s.menuBarDisplay = .timeAndTask
        s.launchAtLogin = true
        s.firstWeekday = 2

        let decoded = AppSettings.decode(try s.encoded())
        #expect(decoded.settings == s)
        #expect(decoded.storedVersion == AppSettings.currentVersion)
        #expect(!decoded.needsResave)
    }

    @Test func encodesCurrentVersion() throws {
        let object = try JSONSerialization.jsonObject(with: try AppSettings.default.encoded()) as? [String: Any]
        #expect(object?["version"] as? Int == AppSettings.currentVersion)
    }

    @Test func unversionedDataMigratesAndKeepsKnownFields() {
        let data = Data(#"{"menuBarDisplay": "iconOnly", "launchAtLogin": true}"#.utf8)
        let decoded = AppSettings.decode(data)
        #expect(decoded.storedVersion == 0)
        #expect(decoded.needsResave)
        #expect(decoded.settings.menuBarDisplay == .iconOnly)
        #expect(decoded.settings.launchAtLogin == true)
        #expect(decoded.settings.presets == Preset.builtIns)
        #expect(decoded.settings.sounds == SoundSettings())
    }

    @Test func newerVersionIsReadButNotRewritten() {
        let data = Data(#"{"version": 99, "launchAtLogin": true, "futureField": [1, 2]}"#.utf8)
        let decoded = AppSettings.decode(data)
        #expect(decoded.storedVersion == 99)
        #expect(!decoded.needsResave)
        #expect(decoded.settings.launchAtLogin == true)
    }

    @Test(arguments: ["", "not json", "[1,2,3]", "null"])
    func unreadableDataYieldsDefaults(_ text: String) {
        let decoded = AppSettings.decode(Data(text.utf8))
        #expect(decoded.settings == .default)
        #expect(decoded.storedVersion == nil)
        #expect(!decoded.needsResave)
    }

    @Test func unknownEnumValuesFallBackPerField() {
        let data = Data(#"""
            {"version": 1, "menuBarDisplay": "hologram",
             "sounds": {"focusEnd": "airhorn", "breakEnd": "bowl", "volume": 7}}
            """#.utf8)
        let s = AppSettings.decode(data).settings
        #expect(s.menuBarDisplay == .time)
        #expect(s.sounds.focusEnd == .chimeFocusEnd)
        #expect(s.sounds.breakEnd == .bowl)
        #expect(s.sounds.volume == 1)
    }

    @Test func malformedPresetIsDroppedAndDanglingDefaultRepaired() {
        let id = "00000000-0000-0000-0000-0000000000AA"
        let data = Data(#"""
            {"version": 1, "defaultPresetID": "00000000-0000-0000-0000-0000000000FF",
             "presets": [{"id": "\#(id)", "name": "  Mine  ", "profile": {"focusDuration": 2400}},
                         {"name": "no id"}]}
            """#.utf8)
        let s = AppSettings.decode(data).settings
        #expect(s.presets.count == 1)
        #expect(s.presets[0].name == "Mine")
        #expect(s.presets[0].profile.focusDuration == 40 * 60)
        #expect(s.defaultPresetID == UUID(uuidString: id))
    }

    @Test func presetWithBadNameOrProfileIsKept() {
        let a = "00000000-0000-0000-0000-0000000000AA"
        let b = "00000000-0000-0000-0000-0000000000BB"
        let data = Data(#"""
            {"version": 1, "defaultPresetID": "\#(b)",
             "presets": [{"id": "\#(a)", "name": 7, "profile": {"focusDuration": 2400}},
                         {"id": "\#(b)", "name": "Mine", "profile": "oops"}]}
            """#.utf8)
        let s = AppSettings.decode(data).settings
        #expect(s.presets.map(\.name) == [Preset.untitledName, "Mine"])
        #expect(s.presets[0].profile.focusDuration == 40 * 60)
        #expect(s.presets[1].profile == .classic)
        #expect(s.defaultPresetID == UUID(uuidString: b))
    }

    @Test func emptyPresetListFallsBackToBuiltIns() {
        let s = AppSettings.decode(Data(#"{"version": 1, "presets": []}"#.utf8)).settings
        #expect(s.presets == Preset.builtIns)
        #expect(s.defaultPreset == .classic)
    }

    @Test func duplicatePresetIDsAreDeduplicated() {
        let s = AppSettings(presets: [.classic, .deep, .classic])
        #expect(s.presets == [.classic, .deep])
    }

    @Test(arguments: [0, 8, -1])
    func invalidFirstWeekdayFollowsSystem(_ value: Int) {
        var s = AppSettings(firstWeekday: value)
        #expect(s.firstWeekday == nil)
        s.firstWeekday = 7
        #expect(s.firstWeekday == 7)
        s.firstWeekday = value
        #expect(s.firstWeekday == nil)
    }

    @Test func volumeIsClamped() {
        var sounds = SoundSettings(volume: -1)
        #expect(sounds.volume == 0)
        sounds.volume = 3
        #expect(sounds.volume == 1)
    }
}

struct PresetManagementTests {
    @Test func builtInsHaveStableIDs() {
        #expect(Preset.classic.id.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(Preset.builtIns.allSatisfy { $0.isBuiltIn })
        #expect(!Preset(name: "Mine", profile: .classic).isBuiltIn)
    }

    @Test func addPreset() {
        var s = AppSettings.default
        let added = s.addPreset(name: "  Sprint ", profile: .deep)
        #expect(added.name == "Sprint")
        #expect(s.presets.last == added)
        #expect(s.preset(id: added.id) == added)
        #expect(s.addPreset(name: "   ", profile: .quick).name == Preset.untitledName)
    }

    @Test func editPreset() throws {
        var s = AppSettings.default
        var deep = try #require(s.preset(id: Preset.deep.id))
        deep.name = "Deep work"
        deep.profile.focusDuration = 60 * 60
        try s.updatePreset(deep)
        #expect(s.preset(id: Preset.deep.id)?.name == "Deep work")
        #expect(s.preset(id: Preset.deep.id)?.profile.focusDuration == TimeInterval(60 * 60))
        #expect(throws: AppSettings.PresetError.notFound) {
            try s.updatePreset(Preset(name: "ghost", profile: .classic))
        }
    }

    @Test func editingDefaultPresetChangesDefaultProfile() throws {
        var s = AppSettings.default
        var classic = s.defaultPreset
        classic.profile.longBreakEvery = 3
        try s.updatePreset(classic)
        #expect(s.defaultProfile.longBreakEvery == 3)
    }

    @Test func deletePreset() throws {
        var s = AppSettings.default
        try s.deletePreset(id: Preset.quick.id)
        #expect(s.presets == [.classic, .deep])
        #expect(throws: AppSettings.PresetError.notFound) { try s.deletePreset(id: Preset.quick.id) }
    }

    @Test func deletingDefaultMovesDefaultToFirstRemaining() throws {
        var s = AppSettings.default
        try s.deletePreset(id: Preset.classic.id)
        #expect(s.defaultPreset == .deep)
    }

    @Test func cannotDeleteLastPreset() throws {
        var s = AppSettings(presets: [.quick])
        #expect(throws: AppSettings.PresetError.cannotDeleteLastPreset) { try s.deletePreset(id: Preset.quick.id) }
        #expect(s.presets == [.quick])
    }

    @Test func setDefaultPreset() throws {
        var s = AppSettings.default
        try s.setDefaultPreset(id: Preset.deep.id)
        #expect(s.defaultProfile == .deep)
        #expect(throws: AppSettings.PresetError.notFound) { try s.setDefaultPreset(id: UUID()) }
        #expect(s.defaultProfile == .deep)
    }

    @Test func movePreset() {
        var s = AppSettings.default
        s.movePreset(fromOffset: 2, toOffset: 0)
        #expect(s.presets == [.quick, .classic, .deep])
        s.movePreset(fromOffset: 0, toOffset: 99)
        #expect(s.presets == [.classic, .deep, .quick])
        s.movePreset(fromOffset: 5, toOffset: 0)
        #expect(s.presets == [.classic, .deep, .quick])
    }

    // Offsets follow SwiftUI's onMove: an insertion point in the original order.
    @Test func movePresetForwardUsesInsertionOffset() {
        var s = AppSettings.default
        s.movePreset(fromOffset: 0, toOffset: 2)
        #expect(s.presets == [.deep, .classic, .quick])
        s.movePreset(fromOffset: 0, toOffset: 1)
        #expect(s.presets == [.deep, .classic, .quick])
    }

    @Test func restoreBuiltInsKeepsEdits() throws {
        var s = AppSettings.default
        var classic = s.defaultPreset
        classic.name = "Mine"
        try s.updatePreset(classic)
        try s.deletePreset(id: Preset.deep.id)
        s.restoreBuiltInPresets()
        #expect(s.presets.map(\.name) == ["Mine", "Quick", "Deep"])
    }

    @Test func updateDefaultProfileEditsOnlyTheDefault() throws {
        var s = AppSettings.default
        try s.setDefaultPreset(id: Preset.deep.id)
        s.updateDefaultProfile { $0.focusDuration = 45 * 60; $0.nudgeInterval = nil }
        #expect(s.defaultProfile.focusDuration == 45 * 60)
        #expect(s.defaultProfile.nudgeInterval == nil)
        #expect(s.preset(id: Preset.classic.id) == .classic)
        #expect(s.preset(id: Preset.quick.id) == .quick)
        #expect(s.presets.map(\.id) == Preset.builtIns.map(\.id))
    }

    @Test func updateDefaultProfileStillClamps() {
        var s = AppSettings.default
        s.updateDefaultProfile { $0.focusDuration = 0; $0.longBreakEvery = 99 }
        #expect(s.defaultProfile.focusDuration == TimerProfile.durationRange.lowerBound)
        #expect(s.defaultProfile.longBreakEvery == TimerProfile.longBreakEveryRange.upperBound)
    }
}

struct AppSettingsAmbientMigrationTests {
    @Test func defaultsAreSilentWithBreaksFadingOut() {
        #expect(AppSettings.default.ambient == AmbientMix())
        #expect(AppSettings.default.ambientPolicy == AmbientPolicy(duringBreaks: .off))
        #expect(AppSettings.currentVersion == 2)
    }

    @Test func ambientRoundTrips() throws {
        var s = AppSettings.default
        s.ambient.toggle("rain")
        s.ambient.toggle("forest")
        s.ambient.setLevel(0.5, for: "forest")
        s.ambient.volume = 0.3
        s.ambientPolicy.duringBreaks = .lower
        let decoded = AppSettings.decode(try s.encoded())
        #expect(decoded.settings == s)
        #expect(!decoded.needsResave)
    }

    @Test func versionOneMigratesToSilentAmbient() throws {
        let data = Data(#"{"version": 1, "menuBarDisplay": "iconOnly", "launchAtLogin": true}"#.utf8)
        let decoded = AppSettings.decode(data)
        #expect(decoded.storedVersion == 1)
        #expect(decoded.needsResave)
        #expect(decoded.settings.menuBarDisplay == .iconOnly)
        #expect(decoded.settings.launchAtLogin)
        #expect(decoded.settings.ambient == AmbientMix())
        #expect(decoded.settings.ambientPolicy == AmbientPolicy())

        let object = try JSONSerialization.jsonObject(with: try decoded.settings.encoded()) as? [String: Any]
        #expect(object?["version"] as? Int == 2)
        #expect(object?["ambient"] != nil)
        #expect(object?["ambientPolicy"] != nil)
    }

    /// Keys a version 1 build never wrote can't be the user's choice, so they don't survive.
    @Test func versionOneIgnoresStrayAmbientKeys() {
        let data = Data(#"{"version": 1, "ambient": {"sounds": ["rain"]}, "ambientPolicy": {"duringBreaks": "keep"}}"#.utf8)
        let settings = AppSettings.decode(data).settings
        #expect(settings.ambient.isEmpty)
        #expect(settings.ambientPolicy.duringBreaks == .off)
    }

    @Test func versionTwoKeepsAmbient() {
        let data = Data(#"{"version": 2, "ambient": {"sounds": ["rain", "rain", "cafe"], "volume": 0.4}, "ambientPolicy": {"duringBreaks": "keep"}}"#.utf8)
        let settings = AppSettings.decode(data).settings
        #expect(settings.ambient.sounds == ["rain", "cafe"])
        #expect(settings.ambient.volume == 0.4)
        #expect(settings.ambientPolicy.duringBreaks == .keep)
    }

    @Test func malformedAmbientFallsBackWithoutLosingTheRest() {
        let data = Data(#"{"version": 2, "ambient": 7, "ambientPolicy": "loud", "launchAtLogin": true}"#.utf8)
        let settings = AppSettings.decode(data).settings
        #expect(settings.ambient == AmbientMix())
        #expect(settings.ambientPolicy == AmbientPolicy())
        #expect(settings.launchAtLogin)
    }
}
