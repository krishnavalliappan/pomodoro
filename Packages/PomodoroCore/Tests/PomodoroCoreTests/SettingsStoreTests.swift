import Foundation
import Testing
@testable import PomodoroCore

struct SettingsStoreTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PomodoroCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func missingDataLoadsDefaults() {
        withSuite { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            #expect(store.load() == .default)
            #expect(defaults.data(forKey: UserDefaultsSettingsStore.defaultKey) == nil)
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withSuite { defaults in
            var s = AppSettings.default
            s.menuBarDisplay = .iconOnly
            s.sounds.volume = 0.3
            s.addPreset(name: "Long haul", profile: TimerProfile(
                focusDuration: 90 * 60, shortBreakDuration: 15 * 60, longBreakDuration: 30 * 60))
            try UserDefaultsSettingsStore(defaults: defaults).save(s)
            #expect(UserDefaultsSettingsStore(defaults: defaults).load() == s)
        }
    }

    @Test func customKeyIsIsolated() throws {
        try withSuite { defaults in
            var s = AppSettings.default
            s.launchAtLogin = true
            try UserDefaultsSettingsStore(defaults: defaults, key: "other").save(s)
            #expect(UserDefaultsSettingsStore(defaults: defaults).load() == .default)
            #expect(UserDefaultsSettingsStore(defaults: defaults, key: "other").load() == s)
        }
    }

    @Test func oldVersionIsMigratedAndRewritten() throws {
        try withSuite { defaults in
            let key = UserDefaultsSettingsStore.defaultKey
            defaults.set(Data(#"{"launchAtLogin": true}"#.utf8), forKey: key)

            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded.launchAtLogin)

            let rewritten = try #require(defaults.data(forKey: key))
            #expect(AppSettings.decode(rewritten).storedVersion == AppSettings.currentVersion)
            #expect(AppSettings.decode(rewritten).settings == loaded)
        }
    }

    @Test func newerVersionIsNotRewritten() {
        withSuite { defaults in
            let key = UserDefaultsSettingsStore.defaultKey
            let original = Data(#"{"version": 42, "launchAtLogin": true}"#.utf8)
            defaults.set(original, forKey: key)
            #expect(UserDefaultsSettingsStore(defaults: defaults).load().launchAtLogin)
            #expect(defaults.data(forKey: key) == original)
        }
    }

    @Test func corruptDataLoadsDefaults() {
        withSuite { defaults in
            defaults.set(Data("garbage".utf8), forKey: UserDefaultsSettingsStore.defaultKey)
            #expect(UserDefaultsSettingsStore(defaults: defaults).load() == .default)
        }
    }

    @Test func inMemoryStore() throws {
        let store = InMemorySettingsStore()
        #expect(store.load() == .default)
        var s = AppSettings.default
        s.launchAtLogin = true
        try store.save(s)
        #expect(store.load() == s)
    }
}
