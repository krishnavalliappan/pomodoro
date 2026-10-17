import Foundation

/// The planner's day timeline as plain numbers: where a time sits vertically, how drags snap
/// and clamp, and which column each block takes when blocks overlap.
///
/// Time maps to y linearly from the start of the visible range, so a DST day is an hour
/// longer or shorter rather than having a stretched hour.
public struct TimelineLayout: Sendable, Equatable {
    public static let defaultSnap: TimeInterval = 15 * 60
    public static let defaultMinimumDuration: TimeInterval = 15 * 60

    public let visible: Range<Date>
    /// Points per hour.
    public let hourHeight: Double
    public let snap: TimeInterval
    public let minimumDuration: TimeInterval
    /// A moment on the snap grid, normally a wall-clock hour. Snap points are this plus whole
    /// multiples of `snap`, so they stay on the wall clock's quarter hours even when the
    /// visible range doesn't start or end on one.
    public let gridOrigin: Date

    /// `gridOrigin` defaults to the visible start.
    public init(
        visible: Range<Date>,
        hourHeight: Double,
        snap: TimeInterval = defaultSnap,
        minimumDuration: TimeInterval = defaultMinimumDuration,
        gridOrigin: Date? = nil
    ) {
        precondition(hourHeight > 0 && snap > 0 && minimumDuration > 0)
        self.visible = visible
        self.hourHeight = hourHeight
        self.snap = snap
        self.minimumDuration = minimumDuration
        self.gridOrigin = gridOrigin ?? visible.lowerBound
    }

    /// `startHour` to `endHour` on `day`, in wall-clock hours of `calendar`'s time zone.
    /// `endHour` 24 is the next midnight.
    public init(
        day: CivilDay,
        calendar: Calendar,
        startHour: Int = 6,
        endHour: Int = 24,
        hourHeight: Double,
        snap: TimeInterval = defaultSnap,
        minimumDuration: TimeInterval = defaultMinimumDuration
    ) {
        precondition(0 <= startHour && startHour < endHour && endHour <= 24)
        let start = Self.wallClock(day, hour: startHour, calendar: calendar)
        let end = Self.wallClock(day, hour: endHour, calendar: calendar)
        self.init(visible: start..<max(end, start + 3600), hourHeight: hourHeight, snap: snap, minimumDuration: minimumDuration)
    }

    public var visibleDuration: TimeInterval { visible.upperBound.timeIntervalSince(visible.lowerBound) }
    public var totalHeight: Double { visibleDuration / 3600 * hourHeight }

    /// The start of each hour row, top to bottom.
    public var hourMarks: [Date] {
        stride(from: 0, to: visibleDuration, by: 3600).map { visible.lowerBound + $0 }
    }

    // MARK: - Conversion

    /// Unclamped: times outside the visible range land above 0 or below `totalHeight`.
    public func y(for date: Date) -> Double {
        date.timeIntervalSince(visible.lowerBound) / 3600 * hourHeight
    }

    public func date(atY y: Double) -> Date {
        visible.lowerBound + interval(forHeight: y)
    }

    public func height(for interval: TimeInterval) -> Double {
        interval / 3600 * hourHeight
    }

    public func interval(forHeight height: Double) -> TimeInterval {
        height / hourHeight * 3600
    }

    /// The nearest snap point. Snap points count from `gridOrigin`, which sits on an hour, so
    /// they fall on the wall clock's quarter hours even in zones offset by :30 or :45.
    public func snapped(_ date: Date) -> Date {
        snapped(date, .toNearestOrAwayFromZero)
    }

    public func isOnGrid(_ date: Date) -> Bool {
        snapped(date) == date
    }

    public func clamped(_ date: Date) -> Date {
        min(max(date, visible.lowerBound), visible.upperBound)
    }

    // MARK: - Drags

    /// The first and last snap points inside the visible range.
    public var firstSlot: Date { snapped(visible.lowerBound, .up) }
    public var lastSlot: Date { max(snapped(visible.upperBound, .down), firstSlot) }

    /// Where a block of `duration` may start: a snap point inside the visible range, or the top
    /// slot if it's longer than the range. Clamping to snap points rather than to the range's
    /// edges keeps a 50-minute block dropped at 23:40 on 23:00, not 23:10.
    public func clampedStart(_ start: Date, duration: TimeInterval) -> Date {
        let latest = max(snapped(visible.upperBound - duration, .down), firstSlot)
        return max(firstSlot, min(snapped(start), latest))
    }

    /// A block's new start after its body is dragged by `delta`.
    public func movedStart(_ start: Date, duration: TimeInterval, by delta: TimeInterval) -> Date {
        clampedStart(start + delta, duration: duration)
    }

    /// A block's new duration after its bottom edge is dragged by `delta`. The start stays put,
    /// even off the grid; the end snaps, stays inside the visible range, and is no earlier than
    /// the first snap point `minimumDuration` after the start. A block too close to the range's
    /// end to meet the minimum keeps its duration, since growing it would push it past the end.
    public func resizedDuration(start: Date, duration: TimeInterval, by delta: TimeInterval) -> TimeInterval {
        let shortest = snapped(start + minimumDuration, .up)
        guard shortest <= lastSlot else { return duration }
        let end = max(min(snapped(start + duration + delta), lastSlot), shortest)
        return end.timeIntervalSince(start)
    }

    /// The start for a block dropped with its top at `date`.
    public func droppedStart(at date: Date, duration: TimeInterval) -> Date {
        clampedStart(date, duration: duration)
    }

    /// The block a drag across empty space describes, in either direction. Both ends are snap
    /// points inside the visible range; one too short for `minimumDuration` grows down, or up
    /// when it would pass the range's end.
    public func creationRange(from a: Date, to b: Date) -> Range<Date> {
        func slot(_ date: Date) -> Date { min(max(snapped(date), firstSlot), lastSlot) }
        var start = slot(min(a, b))
        var end = slot(max(a, b))
        if end.timeIntervalSince(start) < minimumDuration {
            if snapped(start + minimumDuration, .up) <= lastSlot {
                end = snapped(start + minimumDuration, .up)
            } else {
                end = lastSlot
                start = max(snapped(end - minimumDuration, .down), firstSlot)
            }
        }
        return start..<end
    }

    // MARK: - Blocks

    public struct Column: Sendable, Equatable {
        public var index: Int
        /// Columns in this block's cluster: the run of blocks linked by overlaps.
        public var count: Int

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }

        public var x: Double { Double(index) / Double(count) }
        public var width: Double { 1 / Double(count) }
    }

    public struct Frame: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var y: Double
        public var height: Double
        public var column: Column
        /// The block runs past the visible range at the top or bottom.
        public var clippedTop: Bool
        public var clippedBottom: Bool
    }

    /// Frames for the blocks that show, in the order given. Blocks are clipped to the visible
    /// range, and only their visible parts compete for columns.
    public func frames(for blocks: [TimeBlock]) -> [Frame] {
        let shown = blocks.compactMap { block -> (TimeBlock, Range<Date>)? in
            let start = max(block.start, visible.lowerBound)
            let end = min(block.end, visible.upperBound)
            return start < end ? (block, start..<end) : nil
        }
        let columns = Self.columns(for: shown.map(\.1))
        return zip(shown, columns).map { item, column in
            let (block, range) = item
            return Frame(
                id: block.id,
                y: y(for: range.lowerBound),
                height: height(for: range.upperBound.timeIntervalSince(range.lowerBound)),
                column: column,
                clippedTop: block.start < visible.lowerBound,
                clippedBottom: block.end > visible.upperBound
            )
        }
    }

    /// Greedy interval-graph colouring, index-aligned with `intervals`. Each interval takes the
    /// leftmost column free at its start; every interval in a cluster shares its column count.
    /// Intervals are half-open, so one ending at 10:00 doesn't collide with one starting then.
    public static func columns(for intervals: [Range<Date>]) -> [Column] {
        // Earlier first; on a tie the longer one goes left, so it reads as the backdrop.
        let order = intervals.indices.sorted { a, b in
            let (x, y) = (intervals[a], intervals[b])
            if x.lowerBound != y.lowerBound { return x.lowerBound < y.lowerBound }
            if x.upperBound != y.upperBound { return x.upperBound > y.upperBound }
            return a < b
        }
        var result = Array(repeating: Column(index: 0, count: 1), count: intervals.count)
        var cluster: [Int] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func close() {
            for index in cluster { result[index].count = columnEnds.count }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for index in order {
            let interval = intervals[index]
            if interval.lowerBound >= clusterEnd { close() }
            let column = columnEnds.firstIndex { $0 <= interval.lowerBound } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(interval.upperBound)
            } else {
                columnEnds[column] = interval.upperBound
            }
            result[index].index = column
            cluster.append(index)
            clusterEnd = max(clusterEnd, interval.upperBound)
        }
        close()
        return result
    }

    // MARK: - Private

    private func snapped(_ date: Date, _ rule: FloatingPointRoundingRule) -> Date {
        let offset = date.timeIntervalSince(gridOrigin)
        return gridOrigin + (offset / snap).rounded(rule) * snap
    }

    private static func wallClock(_ day: CivilDay, hour: Int, calendar: Calendar) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let midnight = day.start(in: calendar)
        guard hour > 0 else { return midnight }
        guard hour < 24 else {
            // The next day's own start, not this one's plus a day: across a gap at midnight this
            // day may begin at 01:00, and a day added to that lands an hour into the next.
            let noon = gregorian.date(byAdding: .hour, value: 12, to: midnight) ?? midnight + 12 * 3600
            let tomorrow = gregorian.date(byAdding: .day, value: 1, to: noon) ?? noon + 86_400
            return CivilDay(containing: tomorrow, in: gregorian).start(in: gregorian)
        }
        return gregorian.date(bySettingHour: hour, minute: 0, second: 0, of: midnight) ?? midnight + TimeInterval(hour) * 3600
    }
}
