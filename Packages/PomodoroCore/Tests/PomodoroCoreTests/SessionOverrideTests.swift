import Foundation
import Testing
@testable import PomodoroCore

struct SessionOverrideTests {
    @Test func focusOnlyOverrideKeepsBreaks() {
        let result = SessionOverride(focus: 40 * 60).applied(to: .classic)
        #expect(result.focusDuration == 40 * 60)
        #expect(result.shortBreakDuration == 5 * 60)
        #expect(result.longBreakDuration == 15 * 60)
    }

    @Test func breakOverrideReplacesWhicheverBreakFollows() {
        let result = SessionOverride(focus: 50 * 60, break: 10 * 60).applied(to: .classic)
        #expect(result.focusDuration == 50 * 60)
        #expect(result.shortBreakDuration == 10 * 60)
        #expect(result.longBreakDuration == 10 * 60)
        #expect(result.longBreakEvery == TimerProfile.classic.longBreakEvery)
        #expect(result.flowMode == TimerProfile.classic.flowMode)
    }

    @Test func overrideIsClamped() {
        let o = SessionOverride(focus: 0, break: 999 * 60)
        #expect(o.focus == 60)
        #expect(o.breakDuration == TimeInterval(180 * 60))
    }

    @Test func parsesChipInput() {
        #expect(SessionOverride(parsing: "40") == SessionOverride(focus: 40 * 60))
        #expect(SessionOverride(parsing: " 50 / 10 ") == SessionOverride(focus: 50 * 60, break: 10 * 60))
        #expect(SessionOverride(parsing: "500") == SessionOverride(focus: 180 * 60))
    }

    @Test(arguments: ["999999999999", "9223372036854775807", "\(Int.max / 60 + 1)"])
    func hugeFocusInputClampsWithoutOverflow(_ text: String) {
        #expect(SessionOverride(parsing: text) == SessionOverride(focus: 180 * 60))
    }

    @Test(arguments: ["40/999999999999", "40/9223372036854775807"])
    func hugeBreakInputClampsWithoutOverflow(_ text: String) {
        #expect(SessionOverride(parsing: text) == SessionOverride(focus: 40 * 60, break: 180 * 60))
    }

    @Test(arguments: ["", "abc", "9223372036854775808", "0", "-5", "50/", "/10", "1/2/3", "4.5"])
    func rejectsInvalidInput(_ text: String) {
        #expect(SessionOverride(parsing: text) == nil)
    }

    @Test func overrideAppliesToNextSessionOnly() {
        var planner = SessionPlanner()
        planner.setOverride(SessionOverride(focus: 50 * 60, break: 10 * 60))
        #expect(planner.previewProfile(base: .classic).focusDuration == 50 * 60)
        #expect(planner.pendingOverride != nil)

        let first = planner.consumeProfile(base: .classic)
        #expect(first.focusDuration == 50 * 60)
        #expect(planner.pendingOverride == nil)

        let second = planner.consumeProfile(base: .classic)
        #expect(second == .classic)
    }

    @Test func emptyOverrideIsIgnored() {
        var planner = SessionPlanner()
        planner.setOverride(SessionOverride())
        #expect(planner.pendingOverride == nil)
    }

    @Test func clearOverrideDropsIt() {
        var planner = SessionPlanner(pendingOverride: SessionOverride(focus: 30 * 60))
        planner.clearOverride()
        #expect(planner.consumeProfile(base: .classic) == .classic)
    }

    @Test func overrideNeverMutatesOrPersistsDefaults() throws {
        let store = InMemorySettingsStore()
        let settings = store.load()
        var planner = SessionPlanner()
        planner.setOverride(SessionOverride(focus: 50 * 60, break: 10 * 60))
        _ = planner.consumeProfile(base: settings.defaultProfile)
        try store.save(settings)

        #expect(store.load() == .default)
        #expect(store.load().defaultProfile == .classic)
        let json = String(decoding: try settings.encoded(), as: UTF8.self)
        #expect(!json.contains("override"))
    }
}
