import Foundation
import Testing
@testable import PomodoroCore

struct TimelineLayoutTests {
    /// 06:00–24:00 on Saturday 17 October 2026 UTC, 60 pt an hour: one point a minute.
    let layout = TimelineLayout(day: Fixture.day(17), calendar: Fixture.utc, hourHeight: 60)

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 17) -> Date {
        Fixture.date(day: day, hour, minute)
    }

    private func minutes(_ value: Double) -> TimeInterval { value * 60 }

    // MARK: Visible range

    @Test func defaultRangeIsSixToMidnight() {
        #expect(layout.visible == at(6)..<at(0, day: 18))
        #expect(layout.visibleDuration == 18 * 3600)
        #expect(layout.totalHeight == 18 * 60)
        #expect(layout.hourMarks.count == 18)
        #expect(layout.hourMarks.first == at(6))
        #expect(layout.hourMarks.last == at(23))
    }

    @Test func rangeIsParameterized() {
        let work = TimelineLayout(day: Fixture.day(17), calendar: Fixture.utc, startHour: 8, endHour: 18, hourHeight: 40)
        #expect(work.visible == at(8)..<at(18))
        #expect(work.totalHeight == 400)
        let whole = TimelineLayout(day: Fixture.day(17), calendar: Fixture.utc, startHour: 0, endHour: 24, hourHeight: 10)
        #expect(whole.visible == at(0)..<at(0, day: 18))
    }

    @Test func rangeFollowsTheWallClockInTheCalendarsZone() {
        let tokyo = Fixture.calendar("Asia/Tokyo")
        let layout = TimelineLayout(day: Fixture.day(17), calendar: tokyo, hourHeight: 60)
        #expect(layout.visible.lowerBound == Fixture.date(day: 17, 6, calendar: tokyo))
        #expect(layout.visible.upperBound == Fixture.date(day: 18, 0, calendar: tokyo))
    }

    /// Europe/London falls back on 25 October 2026, so 06:00–24:00 is 18 hours but midnight
    /// to 06:00 is 7; spring-forward days are an hour short instead.
    @Test func dstDaysKeepWallClockBounds() {
        let london = Fixture.calendar("Europe/London")
        let fallBack = TimelineLayout(day: Fixture.day(25), calendar: london, startHour: 0, endHour: 24, hourHeight: 60)
        #expect(fallBack.visibleDuration == 25 * 3600)
        #expect(fallBack.hourMarks.count == 25)
        let march = CivilDay(year: 2026, month: 3, day: 29)
        let springForward = TimelineLayout(day: march, calendar: london, startHour: 0, endHour: 24, hourHeight: 60)
        #expect(springForward.visibleDuration == 23 * 3600)
    }

    /// Chile and Lebanon spring forward at midnight, so the day's first instant is 01:00. The
    /// range must still end at the next day's midnight, 18 hours after 06:00, not at 01:00.
    @Test(arguments: [
        ("America/Santiago", CivilDay(year: 2026, month: 9, day: 6)),
        ("Asia/Beirut", CivilDay(year: 2026, month: 3, day: 29)),
    ])
    func aGapAtMidnightDoesntRunIntoTheNextDay(zone: String, day: CivilDay) {
        let calendar = Fixture.calendar(zone)
        #expect(calendar.component(.hour, from: day.start(in: calendar)) == 1, "the zone skips this midnight")
        let layout = TimelineLayout(day: day, calendar: calendar, hourHeight: 60)
        let nextMidnight = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day + 1))!
        #expect(layout.visible.upperBound == nextMidnight)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: layout.visible.upperBound)
                == DateComponents(day: day.day + 1, hour: 0, minute: 0))
        #expect(layout.visibleDuration == 18 * 3600)
        let whole = TimelineLayout(day: day, calendar: calendar, startHour: 0, endHour: 24, hourHeight: 60)
        #expect(whole.visibleDuration == 23 * 3600)
    }

    // MARK: y ↔ time

    @Test func yAndTimeConvert() {
        #expect(layout.y(for: at(6)) == 0)
        #expect(layout.y(for: at(9, 30)) == 210)
        #expect(layout.y(for: at(0, day: 18)) == 1080)
        #expect(layout.y(for: at(5)) == -60, "unclamped above the range")
        #expect(layout.date(atY: 210) == at(9, 30))
        #expect(layout.height(for: minutes(45)) == 45)
        #expect(layout.interval(forHeight: 45) == minutes(45))
    }

    @Test(arguments: [0.0, 1, 59.5, 210, 333.25, 1080])
    func yRoundTrips(y: Double) {
        let other = TimelineLayout(day: Fixture.day(17), calendar: Fixture.utc, hourHeight: 48)
        #expect(abs(layout.y(for: layout.date(atY: y)) - y) < 1e-6)
        #expect(abs(other.y(for: other.date(atY: y)) - y) < 1e-6)
    }

    @Test func timeRoundTrips() {
        for minute in stride(from: 0, through: 18 * 60, by: 7) {
            let date = at(6) + minutes(Double(minute))
            #expect(abs(layout.date(atY: layout.y(for: date)).timeIntervalSince(date)) < 1e-6)
        }
    }

    // MARK: Snapping

    @Test func snapsToTheNearestQuarterHour() {
        #expect(layout.snapped(at(9, 7)) == at(9))
        #expect(layout.snapped(at(9, 8)) == at(9, 15))
        #expect(layout.snapped(at(9, 52)) == at(9, 45))
        #expect(layout.snapped(at(9, 53)) == at(10))
        #expect(layout.snapped(at(9, 30)) == at(9, 30))
        #expect(layout.snapped(at(5, 50)) == at(5, 45), "snaps outside the range too")
    }

    @Test func snapFollowsHalfHourZones() {
        let delhi = Fixture.calendar("Asia/Kolkata")
        let layout = TimelineLayout(day: Fixture.day(17), calendar: delhi, hourHeight: 60)
        let nineOhSeven = Fixture.date(day: 17, 9, 7, calendar: delhi)
        #expect(layout.snapped(nineOhSeven) == Fixture.date(day: 17, 9, calendar: delhi))
    }

    @Test func snapIntervalIsConfigurable() {
        let coarse = TimelineLayout(day: Fixture.day(17), calendar: Fixture.utc, hourHeight: 60, snap: 1800)
        #expect(coarse.snapped(at(9, 14)) == at(9))
        #expect(coarse.snapped(at(9, 16)) == at(9, 30))
    }

    // MARK: Moving

    @Test func moveSnapsTheNewStart() {
        #expect(layout.movedStart(at(9), duration: 3600, by: minutes(20)) == at(9, 15))
        #expect(layout.movedStart(at(9), duration: 3600, by: minutes(-50)) == at(8, 15))
        #expect(layout.movedStart(at(9), duration: 3600, by: minutes(5)) == at(9), "a nudge stays put")
    }

    @Test func moveClampsToTheVisibleRange() {
        #expect(layout.movedStart(at(7), duration: 3600, by: minutes(-120)) == at(6))
        #expect(layout.movedStart(at(22), duration: 3600, by: minutes(180)) == at(23))
        #expect(layout.movedStart(at(22), duration: 30 * 3600, by: 0) == at(6), "longer than the range pins to the top")
    }

    @Test func dropSnapsAndClamps() {
        #expect(layout.droppedStart(at: at(14, 7), duration: 3000) == at(14))
        #expect(layout.droppedStart(at: at(23, 40), duration: 3600) == at(23))
        #expect(layout.droppedStart(at: at(4), duration: 1800) == at(6))
    }

    /// Clamping to `end - duration` would put a 50-minute block at 23:10; the latest quarter
    /// hour it fits from is 23:00.
    @Test func clampingKeepsOddLengthsOnTheGrid() {
        #expect(layout.droppedStart(at: at(23, 40), duration: minutes(50)) == at(23))
        #expect(layout.movedStart(at(21), duration: minutes(50), by: minutes(180)) == at(23))
        #expect(layout.movedStart(at(21), duration: minutes(95), by: minutes(180)) == at(22, 15))
    }

    // MARK: Grid properties

    /// The default day, a range that neither starts nor ends on a quarter hour, and the day a
    /// gap at midnight shortens.
    static let gridLayouts: [TimelineLayout] = {
        let six = Fixture.date(day: 17, 6)
        let santiago = Fixture.calendar("America/Santiago")
        return [
            TimelineLayout(day: Fixture.day(17), calendar: Fixture.utc, hourHeight: 60),
            TimelineLayout(visible: six + 7 * 60 ..< Fixture.date(day: 17, 23, 52), hourHeight: 60, gridOrigin: six),
            TimelineLayout(day: CivilDay(year: 2026, month: 9, day: 6), calendar: santiago, hourHeight: 48),
        ]
    }()

    private static let oddDurations: [Double] = [15, 25, 50, 60, 95, 150, 24 * 60]

    private func onWallClockQuarter(_ date: Date, _ layout: TimelineLayout) -> Bool {
        Int(date.timeIntervalSince(layout.gridOrigin)) % 900 == 0
    }

    private func inside(_ range: Range<Date>, _ layout: TimelineLayout) -> Bool {
        layout.visible.lowerBound <= range.lowerBound && range.upperBound <= layout.visible.upperBound
    }

    @Test(arguments: TimelineLayoutTests.gridLayouts)
    func movesAndDropsLandOnTheGridInsideTheRange(layout: TimelineLayout) {
        let span = layout.lastSlot.timeIntervalSince(layout.firstSlot)
        for length in Self.oddDurations {
            let duration = minutes(length)
            for offset in stride(from: -90.0, through: span / 60 + 90, by: 7) {
                let date = layout.firstSlot + minutes(offset)
                for start in [layout.droppedStart(at: date, duration: duration),
                              layout.movedStart(layout.firstSlot, duration: duration, by: minutes(offset))] {
                    #expect(onWallClockQuarter(start, layout), "\(length) min at \(offset)")
                    #expect(start >= layout.visible.lowerBound)
                    if duration <= span {
                        #expect(inside(start..<start + duration, layout), "\(length) min at \(offset)")
                    }
                }
            }
        }
    }

    @Test(arguments: TimelineLayoutTests.gridLayouts)
    func resizesLandOnTheGridInsideTheRange(layout: TimelineLayout) {
        let span = layout.lastSlot.timeIntervalSince(layout.firstSlot)
        for startOffset in stride(from: 0.0, to: span / 60 - 15, by: 45) {
            let start = layout.firstSlot + minutes(startOffset)
            for delta in stride(from: -600.0, through: 1200, by: 11) {
                let end = start + layout.resizedDuration(start: start, duration: 3600, by: minutes(delta))
                #expect(onWallClockQuarter(end, layout), "from \(startOffset) by \(delta)")
                #expect(inside(start..<end, layout), "from \(startOffset) by \(delta)")
                #expect(end.timeIntervalSince(start) >= layout.minimumDuration)
            }
        }
    }

    @Test(arguments: TimelineLayoutTests.gridLayouts)
    func creationsLandOnTheGridInsideTheRange(layout: TimelineLayout) {
        let span = layout.visibleDuration / 60
        for a in stride(from: -60.0, through: span + 60, by: 13) {
            for b in stride(from: -60.0, through: span + 60, by: 29) {
                let range = layout.creationRange(from: layout.visible.lowerBound + minutes(a), to: layout.visible.lowerBound + minutes(b))
                #expect(onWallClockQuarter(range.lowerBound, layout) && onWallClockQuarter(range.upperBound, layout), "\(a)→\(b)")
                #expect(inside(range, layout), "\(a)→\(b)")
                #expect(range.upperBound.timeIntervalSince(range.lowerBound) >= layout.minimumDuration)
            }
        }
    }

    // MARK: Resizing

    @Test func resizeSnapsTheEnd() {
        #expect(layout.resizedDuration(start: at(9), duration: 3600, by: minutes(20)) == minutes(75))
        #expect(layout.resizedDuration(start: at(9), duration: 3600, by: minutes(-22)) == minutes(45))
    }

    @Test func resizeKeepsTheMinimumDuration() {
        #expect(layout.resizedDuration(start: at(9), duration: 3600, by: minutes(-60)) == minutes(15))
        #expect(layout.resizedDuration(start: at(9), duration: 3600, by: minutes(-300)) == minutes(15))
    }

    @Test func resizeStopsAtTheEndOfTheRange() {
        #expect(layout.resizedDuration(start: at(22), duration: 3600, by: minutes(300)) == minutes(120))
        #expect(layout.resizedDuration(start: at(23, 50), duration: minutes(10), by: minutes(30)) == minutes(15),
                "the minimum wins over the range")
    }

    // MARK: Creating

    @Test func creationSnapsAndOrdersEitherWay() {
        #expect(layout.creationRange(from: at(9, 5), to: at(10, 20)) == at(9)..<at(10, 15))
        #expect(layout.creationRange(from: at(10, 20), to: at(9, 5)) == at(9)..<at(10, 15))
    }

    @Test func creationKeepsTheMinimumDuration() {
        #expect(layout.creationRange(from: at(9, 2), to: at(9, 6)) == at(9)..<at(9, 15))
        #expect(layout.creationRange(from: at(23, 58), to: at(23, 59)) == at(23, 45)..<at(0, day: 18))
    }

    @Test func creationClampsToTheVisibleRange() {
        #expect(layout.creationRange(from: at(4), to: at(7)) == at(6)..<at(7))
        #expect(layout.creationRange(from: at(23), to: at(2, day: 18)) == at(23)..<at(0, day: 18))
    }

    // MARK: Columns

    private func ranges(_ pairs: [(Double, Double)]) -> [Range<Date>] {
        pairs.map { at(0) + $0.0 * 3600 ..< at(0) + $0.1 * 3600 }
    }

    private func placement(_ pairs: [(Double, Double)]) -> [[Int]] {
        TimelineLayout.columns(for: ranges(pairs)).map { [$0.index, $0.count] }
    }

    @Test func separateBlocksTakeTheFullWidth() {
        #expect(placement([(9, 10), (11, 12)]) == [[0, 1], [0, 1]])
        #expect(placement([]) == [])
    }

    @Test func touchingBlocksDontOverlap() {
        #expect(placement([(9, 10), (10, 11)]) == [[0, 1], [0, 1]])
    }

    @Test func twoOverlapsSitSideBySide() {
        #expect(placement([(9, 10), (9.5, 10.5)]) == [[0, 2], [1, 2]])
        let columns = TimelineLayout.columns(for: ranges([(9, 10), (9.5, 10.5)]))
        #expect(columns.map(\.x) == [0, 0.5])
        #expect(columns.map(\.width) == [0.5, 0.5])
    }

    @Test func threeMutualOverlapsTakeThirds() {
        #expect(placement([(9, 11), (9.5, 10.5), (10, 10.25)]) == [[0, 3], [1, 3], [2, 3]])
        let columns = TimelineLayout.columns(for: ranges([(9, 11), (9.5, 10.5), (10, 10.25)]))
        #expect(columns.map(\.width).allSatisfy { abs($0 - 1.0 / 3) < 1e-12 })
    }

    /// A overlaps B, B overlaps C, but A ends before C starts: C reuses A's column, and the
    /// whole chain shares two columns.
    @Test func chainsReuseFreedColumns() {
        #expect(placement([(9, 10), (9.5, 10.5), (10.25, 11)]) == [[0, 2], [1, 2], [0, 2]])
    }

    @Test func aLongBlockSpansAChain() {
        // A long block under two blocks in sequence beside it.
        #expect(placement([(9, 12), (9, 10), (10, 11)]) == [[0, 2], [1, 2], [1, 2]])
    }

    @Test func clustersAreIndependent() {
        #expect(placement([(9, 10), (9.5, 10.5), (9.75, 10.25), (13, 14), (13.5, 14)])
                == [[0, 3], [1, 3], [2, 3], [0, 2], [1, 2]])
    }

    @Test func columnsFollowStartOrderNotInputOrder() {
        #expect(placement([(9.5, 10.5), (9, 10)]) == [[1, 2], [0, 2]])
        #expect(placement([(9, 10), (9, 11)]) == [[1, 2], [0, 2]], "on equal starts the longer goes left")
    }

    // MARK: Frames

    private func block(_ start: Date, minutes length: Double, title: String = "B") -> TimeBlock {
        TimeBlock(title: title, start: start, duration: minutes(length))
    }

    @Test func framesPlaceBlocks() {
        let a = block(at(9), minutes: 60)
        let b = block(at(9, 30), minutes: 60)
        let frames = layout.frames(for: [a, b])
        #expect(frames.map(\.id) == [a.id, b.id])
        #expect(frames.map(\.y) == [180, 210])
        #expect(frames.map(\.height) == [60, 60])
        #expect(frames.map(\.column) == [.init(index: 0, count: 2), .init(index: 1, count: 2)])
        #expect(frames.allSatisfy { !$0.clippedTop && !$0.clippedBottom })
    }

    @Test func framesClipToTheVisibleRange() {
        let early = block(at(5), minutes: 90)
        let late = block(at(23, 30), minutes: 60)
        let hidden = block(at(4), minutes: 60)
        let frames = layout.frames(for: [early, late, hidden])
        #expect(frames.map(\.id) == [early.id, late.id])
        #expect(frames[0].y == 0)
        #expect(frames[0].height == 30)
        #expect(frames[0].clippedTop && !frames[0].clippedBottom)
        #expect(frames[1].height == 30)
        #expect(frames[1].clippedBottom)
    }

    @Test func hiddenOverlapsDontNarrowVisibleBlocks() {
        // Overlapping only before 06:00, so the visible parts don't collide.
        let a = block(at(5), minutes: 70)
        let b = block(at(5, 30), minutes: 30)
        let frames = layout.frames(for: [a, b])
        #expect(frames.map(\.id) == [a.id])
        #expect(frames[0].column.count == 1)
    }
}
