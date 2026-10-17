import Foundation
import Testing
@testable import PomodoroCore

private func calendar(_ zone: String, locale: String = "en_US_POSIX") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    cal.locale = Locale(identifier: locale)
    return cal
}

private func utc(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private let newYork = calendar("America/New_York")
/// Wednesday 2026-03-04 10:00 EST, four days before the spring-forward transition.
private let wednesday = utc("2026-03-04T15:00:00Z")

struct QuickAddCase: Sendable, CustomTestStringConvertible {
    let input: String
    let title: String
    var estimate: Int? = nil
    var tag: String? = nil
    /// Days after 2026-03-04.
    var day: Int? = nil
    var start: (hour: Int, minute: Int)? = nil
    var minutes: Int? = nil

    var testDescription: String { "\"\(input)\"" }
}

private let cases: [QuickAddCase] = [
    // The issue's example and token order
    .init(input: "Write spec ~3 @14:00 45m #work tomorrow", title: "Write spec", estimate: 3, tag: "work",
          day: 1, start: (14, 0), minutes: 45),
    .init(input: "@14:00 Standup ~1 #team", title: "Standup", estimate: 1, tag: "team",
          day: 0, start: (14, 0), minutes: 25),
    .init(input: "#deep-work/q3 Plan roadmap", title: "Plan roadmap", tag: "deep-work/q3"),

    // Title
    .init(input: "Write spec", title: "Write spec"),
    .init(input: "  Write \t  spec  ", title: "Write spec"),
    .init(input: "", title: ""),
    .init(input: "~3 #work", title: "", estimate: 3, tag: "work"),
    .init(input: "1h30m", title: "", minutes: 90),

    // Estimate
    .init(input: "Read ~2", title: "Read", estimate: 2),
    .init(input: "Ship ~2 ~5", title: "Ship", estimate: 2),
    .init(input: "Read ~0", title: "Read ~0"),
    .init(input: "Read ~", title: "Read ~"),
    .init(input: "Read ~abc", title: "Read ~abc"),
    .init(input: "Read ~100", title: "Read ~100"),
    .init(input: "Read ~+2", title: "Read ~+2"),

    // Block start
    .init(input: "Call @9", title: "Call", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Call @9:30", title: "Call", day: 0, start: (9, 30), minutes: 30),
    .init(input: "Call @2pm", title: "Call", day: 0, start: (14, 0), minutes: 30),
    .init(input: "Call @2:15PM", title: "Call", day: 0, start: (14, 15), minutes: 30),
    .init(input: "Call @9am", title: "Call", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Call @12am", title: "Call", day: 0, start: (0, 0), minutes: 30),
    .init(input: "Call @12pm", title: "Call", day: 0, start: (12, 0), minutes: 30),
    .init(input: "Call @12:30am", title: "Call", day: 0, start: (0, 30), minutes: 30),
    .init(input: "Call @0", title: "Call", day: 0, start: (0, 0), minutes: 30),
    .init(input: "Call @23:59", title: "Call", day: 0, start: (23, 59), minutes: 30),
    .init(input: "Plan @9 @10", title: "Plan", day: 0, start: (9, 0), minutes: 30),

    // Invalid times stay in the title
    .init(input: "Call @24:00", title: "Call @24:00"),
    .init(input: "Call @13pm", title: "Call @13pm"),
    .init(input: "Call @0am", title: "Call @0am"),
    .init(input: "Call @9:60", title: "Call @9:60"),
    .init(input: "Call @9:5", title: "Call @9:5"),
    .init(input: "Call @123", title: "Call @123"),
    .init(input: "Call @", title: "Call @"),
    .init(input: "Call @noon", title: "Call @noon"),
    .init(input: "Email @alice", title: "Email @alice"),

    // Duration
    .init(input: "Focus 45m", title: "Focus", minutes: 45),
    .init(input: "Focus 2h", title: "Focus", minutes: 120),
    .init(input: "Focus 1h30m", title: "Focus", minutes: 90),
    .init(input: "Focus 1H30M", title: "Focus", minutes: 90),
    .init(input: "Focus 24h", title: "Focus", minutes: 1440),
    .init(input: "Ship 45m 30m", title: "Ship", minutes: 45),
    .init(input: "Focus 0m", title: "Focus 0m"),
    .init(input: "Focus 25h", title: "Focus 25h"),
    .init(input: "Focus 1h30", title: "Focus 1h30"),
    .init(input: "Focus 1.5h", title: "Focus 1.5h"),
    .init(input: "Focus @9 ~3", title: "Focus", estimate: 3, day: 0, start: (9, 0), minutes: 75),
    .init(input: "Focus @9 ~3 50m", title: "Focus", estimate: 3, day: 0, start: (9, 0), minutes: 50),

    // Tags and escapes
    .init(input: "Tags #a #b", title: "Tags", tag: "a"),
    .init(input: "Fix \\#123", title: "Fix #123"),
    .init(input: "Fix \\# thing", title: "Fix # thing"),
    .init(input: "Pay \\~5 \\@9 \\45m", title: "Pay ~5 @9 45m"),
    .init(input: "\\tomorrow is fine", title: "tomorrow is fine"),
    .init(input: "Weird \\n path", title: "Weird \\n path"),
    .init(input: "Lone # sign", title: "Lone # sign"),
    .init(input: "Tag #work,", title: "Tag #work,"),
    .init(input: "Issue #123", title: "Issue", tag: "123"),

    // Day
    .init(input: "Plan today", title: "Plan", day: 0),
    .init(input: "Plan TOMORROW", title: "Plan", day: 1),
    .init(input: "Plan friday", title: "Plan", day: 2),
    .init(input: "Plan Wednesday", title: "Plan", day: 0),
    .init(input: "Plan tuesday", title: "Plan", day: 6),
    .init(input: "Plan monday @9", title: "Plan", day: 5, start: (9, 0), minutes: 30),
    .init(input: "Plan today tomorrow", title: "Plan", day: 0),
    .init(input: "Sit in the sun", title: "Sit in the sun"),
    .init(input: "Read today's news", title: "Read today's news"),
]

struct QuickAddParserTests {
    let parser = QuickAddParser(calendar: newYork)

    @Test(arguments: cases)
    func parses(_ c: QuickAddCase) {
        let result = parser.parse(c.input, now: wednesday)

        let expectedDay = c.day.map { newYork.date(from: DateComponents(year: 2026, month: 3, day: 4 + $0))! }
        let expectedStart = c.start.map { start in
            newYork.date(from: DateComponents(year: 2026, month: 3, day: 4 + (c.day ?? 0),
                                              hour: start.hour, minute: start.minute))!
        }
        #expect(result == QuickAddResult(
            title: c.title,
            estimate: c.estimate,
            tag: c.tag,
            day: expectedDay,
            blockStart: expectedStart,
            blockDuration: c.minutes.map { TimeInterval($0 * 60) }
        ))
    }

    @Test func blockDefaultsFollowConfiguredLengths() {
        let parser = QuickAddParser(calendar: newYork, pomodoroLength: 50 * 60, defaultBlockDuration: 15 * 60)
        let estimated: TimeInterval? = parser.parse("Deep ~2 @9", now: wednesday).blockDuration
        let fallback: TimeInterval? = parser.parse("Quick @9", now: wednesday).blockDuration
        #expect(estimated == TimeInterval(100 * 60))
        #expect(fallback == TimeInterval(15 * 60))
    }

    @Test func timeAlreadyPassedStaysToday() {
        let start = parser.parse("Late @8", now: wednesday).blockStart
        #expect(start == utc("2026-03-04T13:00:00Z"))
    }

    @Test func localizedWeekdayNamesFollowCalendarLocale() {
        let berlin = QuickAddParser(calendar: calendar("Europe/Berlin", locale: "de_DE"))
        let result = berlin.parse("Planen Freitag", now: wednesday)
        #expect(result.title == "Planen")
        #expect(result.day == utc("2026-03-05T23:00:00Z"))
        #expect(berlin.parse("Plan friday", now: wednesday).day == utc("2026-03-05T23:00:00Z"))
    }

    @Test func injectedTimeZoneDecidesTheDay() {
        // 15:00Z is already Thursday in Tokyo.
        let tokyo = QuickAddParser(calendar: calendar("Asia/Tokyo"))
        let result = tokyo.parse("Call @9 tomorrow", now: wednesday)
        #expect(result.day == utc("2026-03-05T15:00:00Z"))
        #expect(result.blockStart == utc("2026-03-06T00:00:00Z"))
    }
}

struct QuickAddParserDSTTests {
    let parser = QuickAddParser(calendar: newYork)
    /// Saturday 12:00 EST, the day before clocks spring forward.
    let beforeSpring = utc("2026-03-07T17:00:00Z")
    /// Saturday 12:00 EDT, the day before clocks fall back.
    let beforeFall = utc("2026-10-31T16:00:00Z")

    @Test func springForwardKeepsWallClockTime() {
        let result = parser.parse("Run tomorrow @14:00", now: beforeSpring)
        #expect(result.day == utc("2026-03-08T05:00:00Z"))
        #expect(result.blockStart == utc("2026-03-08T18:00:00Z"))
    }

    @Test func skippedTimeSnapsToEndOfGap() {
        let result = parser.parse("Run tomorrow @2:30", now: beforeSpring)
        #expect(result.blockStart == utc("2026-03-08T07:00:00Z"))
    }

    @Test func fallBackKeepsWallClockTime() {
        let result = parser.parse("Run tomorrow @9", now: beforeFall)
        #expect(result.day == utc("2026-11-01T04:00:00Z"))
        #expect(result.blockStart == utc("2026-11-01T14:00:00Z"))
    }

    @Test func repeatedTimeUsesFirstOccurrence() {
        let result = parser.parse("Run tomorrow @1:30", now: beforeFall)
        #expect(result.blockStart == utc("2026-11-01T05:30:00Z"))
    }

    @Test func weekdayAcrossTransitionLandsOnLocalMidnight() {
        #expect(parser.parse("Plan monday", now: beforeFall).day == utc("2026-11-02T05:00:00Z"))
        #expect(parser.parse("Plan monday", now: beforeSpring).day == utc("2026-03-09T04:00:00Z"))
    }

    @Test func lateEveningTomorrowIsNextCalendarDay() {
        let lateSaturday = utc("2026-03-08T04:30:00Z") // 23:30 EST
        #expect(parser.parse("Run tomorrow", now: lateSaturday).day == utc("2026-03-08T05:00:00Z"))
    }
}
