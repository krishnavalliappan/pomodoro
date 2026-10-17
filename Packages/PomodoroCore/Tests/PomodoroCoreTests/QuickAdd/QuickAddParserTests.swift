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
    .init(input: "1h30m", title: "1h30m"),
    .init(input: "Learn C# basics", title: "Learn C# basics"),
    .init(input: "Visit site.com/#x", title: "Visit site.com/#x"),
    .init(input: "Email @john", title: "Email @john"),
    .init(input: "Café 会議 👩🏽‍💻 ~2", title: "Café 会議 👩🏽‍💻", estimate: 2),
    .init(input: "👨‍👩‍👧 Família #casa amanhã", title: "👨‍👩‍👧 Família amanhã", tag: "casa"),

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
    .init(input: "Call @2:30PM", title: "Call", day: 0, start: (14, 30), minutes: 30),
    .init(input: "Call @9am", title: "Call", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Call @12am", title: "Call", day: 0, start: (0, 0), minutes: 30),
    .init(input: "Call @12pm", title: "Call", day: 0, start: (12, 0), minutes: 30),
    .init(input: "Call @12:30am", title: "Call", day: 0, start: (0, 30), minutes: 30),
    .init(input: "Call @0", title: "Call", day: 0, start: (0, 0), minutes: 30),
    .init(input: "Call @23:59", title: "Call", day: 0, start: (23, 59), minutes: 30),
    .init(input: "Plan @9 @10", title: "Plan", day: 0, start: (9, 0), minutes: 30),

    // Invalid times stay in the title
    .init(input: "Call @24:00", title: "Call @24:00"),
    .init(input: "Call @24", title: "Call @24"),
    .init(input: "Call @0pm", title: "Call @0pm"),
    .init(input: "Call @13pm", title: "Call @13pm"),
    .init(input: "Call @0am", title: "Call @0am"),
    .init(input: "Call @9:60", title: "Call @9:60"),
    .init(input: "Call @9:5", title: "Call @9:5"),
    .init(input: "Call @123", title: "Call @123"),
    .init(input: "Call @", title: "Call @"),
    .init(input: "Call @noon", title: "Call @noon"),
    .init(input: "Email @alice", title: "Email @alice"),

    // Duration: only in the trailing group, and only with a start
    .init(input: "Focus @9 45m", title: "Focus", day: 0, start: (9, 0), minutes: 45),
    .init(input: "Focus @9 2h", title: "Focus", day: 0, start: (9, 0), minutes: 120),
    .init(input: "Focus 1h30m @9", title: "Focus", day: 0, start: (9, 0), minutes: 90),
    .init(input: "Focus @9 1H30M", title: "Focus", day: 0, start: (9, 0), minutes: 90),
    .init(input: "Focus @9 24h", title: "Focus", day: 0, start: (9, 0), minutes: 1440),
    .init(input: "Ship @9 45m 30m", title: "Ship", day: 0, start: (9, 0), minutes: 45),
    .init(input: "Read article @9 45m", title: "Read article", day: 0, start: (9, 0), minutes: 45),
    .init(input: "Write spec 45m", title: "Write spec 45m"),
    .init(input: "Read 5m article", title: "Read 5m article"),
    .init(input: "Read 5m article @9", title: "Read 5m article", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Read 5m article @9 20m", title: "Read 5m article", day: 0, start: (9, 0), minutes: 20),
    .init(input: "Call 45m tomorrow", title: "Call 45m", day: 1),
    .init(input: "Focus @9 0m", title: "Focus 0m", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Focus @9 25h", title: "Focus 25h", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Focus @9 1h30", title: "Focus 1h30", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Focus @9 1.5h", title: "Focus 1.5h", day: 0, start: (9, 0), minutes: 30),
    .init(input: "Focus @9 ~3", title: "Focus", estimate: 3, day: 0, start: (9, 0), minutes: 75),
    .init(input: "Focus @9 ~3 50m", title: "Focus", estimate: 3, day: 0, start: (9, 0), minutes: 50),

    // Tags and escapes
    .init(input: "Tags #a #b", title: "Tags", tag: "a"),
    .init(input: "Fix \\#123", title: "Fix #123"),
    .init(input: "Fix \\# thing", title: "Fix # thing"),
    .init(input: "Pay \\~5 \\@9 \\45m", title: "Pay ~5 @9 45m"),
    .init(input: "\\tomorrow is fine", title: "tomorrow is fine"),
    .init(input: "See you \\tomorrow", title: "See you tomorrow"),
    .init(input: "Plan \\friday tomorrow", title: "Plan friday", day: 1),
    .init(input: "Plan tomorrow \\#x", title: "Plan tomorrow #x"),
    .init(input: "Focus @9 \\45m", title: "Focus 45m", day: 0, start: (9, 0), minutes: 30),
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
    .init(input: "Call mom tomorrow", title: "Call mom", day: 1),
    .init(input: "Prep Monday standup notes", title: "Prep Monday standup notes"),
    .init(input: "Prep standup notes Monday @9", title: "Prep standup notes", day: 5, start: (9, 0), minutes: 30),
    .init(input: "Call mom tomorrow morning", title: "Call mom tomorrow morning"),
    .init(input: "Plan friday party @9 friday", title: "Plan friday party", day: 2, start: (9, 0), minutes: 30),
    .init(input: "Today #standup notes", title: "Today notes", tag: "standup"),
    .init(input: "Lunch @12 with Sam friday", title: "Lunch with Sam", day: 2, start: (12, 0), minutes: 30),
    .init(input: "Tomorrow", title: "", day: 1),
    .init(input: "Sit in the sun", title: "Sit in the sun"),
    .init(input: "Read today's news", title: "Read today's news"),
]

struct QuickAddParserTests {
    let parser = QuickAddParser(calendar: newYork)

    @Test(arguments: cases)
    func parses(_ c: QuickAddCase) {
        let result = parser.parse(c.input, now: wednesday)

        let expectedDay = c.day.map { CivilDay(year: 2026, month: 3, day: 4 + $0) }
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
        #expect(result.day == CivilDay(year: 2026, month: 3, day: 6))
        #expect(berlin.parse("Plan friday", now: wednesday).day == CivilDay(year: 2026, month: 3, day: 6))
        #expect(berlin.parse("Freitag Party planen", now: wednesday) == QuickAddResult(title: "Freitag Party planen"))
        #expect(berlin.parse("Sonntag Brunch Sonntag", now: wednesday)
            == QuickAddResult(title: "Sonntag Brunch", day: CivilDay(year: 2026, month: 3, day: 8)))
    }

    @Test func injectedTimeZoneDecidesTheDay() {
        // 15:00Z is already Thursday in Tokyo.
        let tokyo = QuickAddParser(calendar: calendar("Asia/Tokyo"))
        let result = tokyo.parse("Call @9 tomorrow", now: wednesday)
        #expect(result.day == CivilDay(year: 2026, month: 3, day: 6))
        #expect(result.blockStart == utc("2026-03-06T00:00:00Z"))
    }

    @Test func civilDaySurvivesAZoneChange() {
        // Late Thursday in Berlin is still Thursday afternoon in New York.
        let berlin = QuickAddParser(calendar: calendar("Europe/Berlin"))
        let day = berlin.parse("Plan tomorrow", now: utc("2026-03-05T22:30:00Z")).day
        #expect(day == CivilDay(year: 2026, month: 3, day: 6))
        #expect(day?.start(in: newYork) == utc("2026-03-06T05:00:00Z"))
        let task = TaskItem(title: "Plan", createdAt: wednesday, scheduledDay: day)
        #expect(task.scheduledDay == CivilDay(year: 2026, month: 3, day: 6))
    }

    @Test func nonGregorianCalendarStillYieldsGregorianCivilDay() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = newYork.timeZone
        buddhist.locale = Locale(identifier: "en_US_POSIX")
        let result = QuickAddParser(calendar: buddhist).parse("Plan friday @9", now: wednesday)
        #expect(result.day == CivilDay(year: 2026, month: 3, day: 6))
        #expect(result.blockStart == utc("2026-03-06T14:00:00Z"))
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
        #expect(result.day == CivilDay(year: 2026, month: 3, day: 8))
        #expect(result.blockStart == utc("2026-03-08T18:00:00Z"))
    }

    @Test func skippedTimeSnapsToEndOfGap() {
        let result = parser.parse("Run tomorrow @2:30", now: beforeSpring)
        #expect(result.blockStart == utc("2026-03-08T07:00:00Z"))
    }

    @Test func fallBackKeepsWallClockTime() {
        let result = parser.parse("Run tomorrow @9", now: beforeFall)
        #expect(result.day == CivilDay(year: 2026, month: 11, day: 1))
        #expect(result.blockStart == utc("2026-11-01T14:00:00Z"))
    }

    @Test func repeatedTimeUsesFirstOccurrence() {
        let result = parser.parse("Run tomorrow @1:30", now: beforeFall)
        #expect(result.blockStart == utc("2026-11-01T05:30:00Z"))
    }

    @Test func weekdayAcrossTransitionLandsOnTheRightDay() {
        #expect(parser.parse("Plan monday", now: beforeFall).day == CivilDay(year: 2026, month: 11, day: 2))
        #expect(parser.parse("Plan monday", now: beforeSpring).day == CivilDay(year: 2026, month: 3, day: 9))
    }

    @Test func lateEveningTomorrowIsNextCalendarDay() {
        let lateSaturday = utc("2026-03-08T04:30:00Z") // 23:30 EST
        #expect(parser.parse("Run tomorrow", now: lateSaturday).day == CivilDay(year: 2026, month: 3, day: 8))
    }
}
