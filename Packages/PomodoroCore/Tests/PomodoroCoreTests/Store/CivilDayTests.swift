import Foundation
import Testing
@testable import PomodoroCore

struct CivilDayTests {
    @Test func formatsAndParsesISO() {
        let day = CivilDay(year: 2026, month: 3, day: 7)
        #expect(day.isoString == "2026-03-07")
        #expect(CivilDay("2026-03-07") == day)
        #expect(CivilDay("2028-02-29") == CivilDay(year: 2028, month: 2, day: 29))
    }

    @Test func rejectsMalformedOrNonexistentDays() {
        for string in ["2026-3-07", "2026-02-30", "2026-13-01", "2026-00-10", "26-03-07", "2026-03-07T00:00", ""] {
            #expect(CivilDay(string) == nil, "\(string)")
        }
    }

    @Test func ordersChronologicallyLikeItsISOString() {
        let days = [
            CivilDay(year: 2026, month: 10, day: 9),
            CivilDay(year: 2026, month: 9, day: 30),
            CivilDay(year: 2025, month: 12, day: 31),
            CivilDay(year: 2026, month: 10, day: 10),
        ]
        #expect(days.sorted().map(\.isoString) == days.map(\.isoString).sorted())
    }

    @Test func dayContainingDependsOnTimeZone() {
        let instant = Fixture.date(day: 18, 2)  // 02:00 UTC on Oct 18
        #expect(CivilDay(containing: instant, in: Fixture.utc) == Fixture.day(18))
        #expect(CivilDay(containing: instant, in: Fixture.calendar("America/Los_Angeles")) == Fixture.day(17))
    }

    @Test func startIsMidnightInTheGivenZone() {
        let berlin = Fixture.calendar("Europe/Berlin")
        #expect(Fixture.day(25).start(in: berlin) == Fixture.date(day: 25, calendar: berlin))
        // São Paulo skipped midnight on its 2018-11-04 DST change; the day starts at 01:00.
        let saoPaulo = Fixture.calendar("America/Sao_Paulo")
        let start = CivilDay(year: 2018, month: 11, day: 4).start(in: saoPaulo)
        #expect(CivilDay(containing: start, in: saoPaulo) == CivilDay(year: 2018, month: 11, day: 4))
    }

    @Test func codableUsesISOString() throws {
        let data = try JSONEncoder().encode([Fixture.day(18)])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-10-18"]"#)
        #expect(try JSONDecoder().decode([CivilDay].self, from: data) == [Fixture.day(18)])
    }
}
