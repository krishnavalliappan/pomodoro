import Foundation
import Testing
@testable import PomodoroCore

struct TimerProfileTests {
    @Test func classicDefaults() {
        let p = TimerProfile.classic
        #expect(p.focusDuration == 25 * 60)
        #expect(p.shortBreakDuration == 5 * 60)
        #expect(p.longBreakDuration == 15 * 60)
        #expect(p.longBreakEvery == 4)
        #expect(p.autoStartBreaks == false)
        #expect(p.autoStartFocus == false)
        #expect(p.flowMode == true)
        #expect(p.nudgeInterval == 10 * 60)
        #expect(p.summary == "25/5/15")
    }

    @Test func builtInSummaries() {
        #expect(TimerProfile.deep.summary == "50/10/20")
        #expect(TimerProfile.quick.summary == "15/3/10")
    }

    @Test(arguments: [
        (0.0, 60.0), (-5.0, 60.0), (59.0, 60.0), (60.0, 60.0), (90.0 * 60, 90.0 * 60),
        (180.0 * 60, 180.0 * 60), (181.0 * 60, 180.0 * 60), (Double.infinity, 60.0), (Double.nan, 60.0),
    ])
    func clampsDurationsToOneThrough180Minutes(input: TimeInterval, expected: TimeInterval) {
        let p = TimerProfile(
            focusDuration: input, shortBreakDuration: input, longBreakDuration: input, nudgeInterval: input)
        #expect(p.focusDuration == expected)
        #expect(p.shortBreakDuration == expected)
        #expect(p.longBreakDuration == expected)
        #expect(p.nudgeInterval == expected)
    }

    @Test func clampsOnMutation() {
        var p = TimerProfile.classic
        p.focusDuration = 0
        p.shortBreakDuration = 1_000_000
        p.longBreakDuration = -1
        p.longBreakEvery = 0
        p.nudgeInterval = 1
        #expect(p.focusDuration == 60)
        #expect(p.shortBreakDuration == 180 * 60)
        #expect(p.longBreakDuration == 60)
        #expect(p.longBreakEvery == 1)
        #expect(p.nudgeInterval == 60)
        p.longBreakEvery = 99
        #expect(p.longBreakEvery == 16)
        p.nudgeInterval = nil
        #expect(p.nudgeInterval == nil)
    }

    @Test func codableRoundTrip() throws {
        let p = TimerProfile(
            focusDuration: 40 * 60, shortBreakDuration: 7 * 60, longBreakDuration: 25 * 60, longBreakEvery: 3,
            autoStartBreaks: true, autoStartFocus: true, flowMode: false, nudgeInterval: nil)
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(TimerProfile.self, from: data) == p)
    }

    @Test func disabledNudgeEncodesAsNullAndStaysDisabled() throws {
        var p = TimerProfile.classic
        p.nudgeInterval = nil
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(json.contains("\"nudgeInterval\":null"))
        #expect(try JSONDecoder().decode(TimerProfile.self, from: Data(json.utf8)).nudgeInterval == nil)
    }

    @Test func missingFieldsFallBackToClassic() throws {
        let data = Data(#"{"focusDuration": 3000}"#.utf8)
        let p = try JSONDecoder().decode(TimerProfile.self, from: data)
        var expected = TimerProfile.classic
        expected.focusDuration = 3000
        #expect(p == expected)
    }

    @Test func malformedAndOutOfRangeFieldsAreRepaired() throws {
        let data = Data(#"{"focusDuration": "soon", "shortBreakDuration": 1, "longBreakEvery": -3}"#.utf8)
        let p = try JSONDecoder().decode(TimerProfile.self, from: data)
        #expect(p.focusDuration == 25 * 60)
        #expect(p.shortBreakDuration == 60)
        #expect(p.longBreakEvery == 1)
    }
}
