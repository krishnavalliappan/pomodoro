import Foundation
@testable import PomodoroCore

enum Fixture {
    static let utc = calendar("UTC")

    static func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }

    static func day(_ day: Int, month: Int = 10) -> CivilDay {
        CivilDay(year: 2026, month: month, day: day)
    }

    /// A moment on October `day`, 2026, in `calendar`'s time zone.
    static func date(
        day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0,
        calendar: Calendar = utc
    ) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    static func database(calendar: Calendar = utc) throws -> AppDatabase {
        try AppDatabase.inMemory(calendar: calendar)
    }
}
