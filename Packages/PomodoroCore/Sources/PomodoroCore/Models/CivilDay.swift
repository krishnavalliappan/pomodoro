import Foundation
import GRDB

/// A Gregorian calendar date with no time or zone, stored as `YYYY-MM-DD`.
/// Scheduling a task for "October 18" must stay October 18 when the Mac changes
/// time zone, which an absolute midnight `Date` cannot guarantee.
public struct CivilDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        precondition((1...9999).contains(year) && (1...12).contains(month) && (1...31).contains(day))
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    /// Always read in Gregorian so the key is stable even if `calendar` is not.
    public init(containing date: Date, in calendar: Calendar) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Strict `YYYY-MM-DD`; rejects dates that don't exist, such as `2026-02-30`.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard string.count == 10, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let candidate = CivilDay(year: year, month: month, day: day)
        guard CivilDay(containing: candidate.start(in: Self.utc), in: Self.utc) == candidate else { return nil }
        self = candidate
    }

    /// Zero-padded so lexical order in SQL matches chronological order.
    public var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight (or the first moment, across DST gaps) of this day in `calendar`'s time zone.
    public func start(in calendar: Calendar) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let noon = gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return gregorian.startOfDay(for: noon)
    }

    /// 1 = Sunday … 7 = Saturday, like `Calendar.firstWeekday`. The same in every time zone.
    public var weekday: Int {
        Self.utc.component(.weekday, from: start(in: Self.utc))
    }

    /// Counted in civil days, so it never lands on the wrong day across a DST change.
    public func adding(days: Int) -> CivilDay {
        CivilDay(containing: Self.utc.date(byAdding: .day, value: days, to: start(in: Self.utc))!, in: Self.utc)
    }

    /// Whole days from `self` to `other`; negative when `other` is earlier.
    public func days(to other: CivilDay) -> Int {
        Self.utc.dateComponents([.day], from: start(in: Self.utc), to: other.start(in: Self.utc)).day!
    }

    public static func < (lhs: CivilDay, rhs: CivilDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

extension CivilDay: CustomStringConvertible {
    public var description: String { isoString }
}

extension CivilDay: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = CivilDay(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid civil day \(string)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

extension CivilDay: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { isoString.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CivilDay? {
        String.fromDatabaseValue(dbValue).flatMap(CivilDay.init)
    }
}
