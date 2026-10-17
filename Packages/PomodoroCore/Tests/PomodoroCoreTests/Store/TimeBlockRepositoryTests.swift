import Foundation
import Testing
@testable import PomodoroCore

// Observation tests await stream values; fail fast instead of hanging CI if one never arrives.
@Suite(.timeLimit(.minutes(1)))
struct TimeBlockRepositoryTests {
    let db: AppDatabase

    init() throws {
        db = try Fixture.database()
    }

    @discardableResult
    private func block(
        _ title: String, day: Int = 17, _ hour: Int, _ minute: Int = 0, minutes: Double = 60, taskID: UUID? = nil
    ) throws -> TimeBlock {
        let block = TimeBlock(
            taskID: taskID, title: title, start: Fixture.date(day: day, hour, minute), duration: minutes * 60
        )
        try db.blocks.insert(block)
        return block
    }

    @Test func insertFetchUpdateDeleteRoundTrip() throws {
        let task = try db.tasks.create(title: "Write", createdAt: Fixture.date(day: 17))
        var block = TimeBlock(
            taskID: task.id, title: "Write", start: Fixture.date(day: 17, 9), duration: 2700, color: "#FF6347"
        )
        try db.blocks.insert(block)
        #expect(try db.blocks.fetch(id: block.id) == block)

        block.title = "Write spec"
        block.color = nil
        try db.blocks.update(block)
        #expect(try db.blocks.fetch(id: block.id) == block)

        #expect(try db.blocks.delete(id: block.id))
        #expect(try db.blocks.fetch(id: block.id) == nil)
    }

    @Test func endIsStartPlusDuration() {
        let block = TimeBlock(title: "B", start: Fixture.date(day: 17, 9), duration: 1800)
        #expect(block.end == Fixture.date(day: 17, 9, 30))
        #expect(block.contains(Fixture.date(day: 17, 9)))
        #expect(!block.contains(Fixture.date(day: 17, 9, 30)))
    }

    @Test func rejectsNonPositiveDurations() throws {
        let zero = TimeBlock(title: "Zero", start: Fixture.date(day: 17, 9), duration: 0)
        #expect(throws: StoreError.invalidDuration(0)) { try db.blocks.insert(zero) }

        let ok = try block("OK", 9)
        #expect(throws: StoreError.invalidDuration(-60)) { try db.blocks.resize(id: ok.id, duration: -60) }
        var bad = ok
        bad.duration = 0
        #expect(throws: StoreError.invalidDuration(0)) { try db.blocks.update(bad) }
        #expect(try db.blocks.fetch(id: ok.id) == ok)
    }

    @Test func missingBlockThrowsNotFound() throws {
        let ghost = TimeBlock(title: "Ghost", start: Fixture.date(day: 17, 9), duration: 60)
        #expect(throws: StoreError.notFound(ghost.id)) { try db.blocks.update(ghost) }
        #expect(throws: StoreError.notFound(ghost.id)) { try db.blocks.move(id: ghost.id, to: Fixture.date(day: 17)) }
        #expect(throws: StoreError.notFound(ghost.id)) { try db.blocks.resize(id: ghost.id, duration: 60) }
    }

    @Test func moveKeepsDurationAndResizeKeepsStart() throws {
        let original = try block("B", 9, minutes: 45)

        let moved = try db.blocks.move(id: original.id, to: Fixture.date(day: 17, 13, 15))
        #expect(moved.start == Fixture.date(day: 17, 13, 15))
        #expect(moved.duration == 2700)
        #expect(try db.blocks.fetch(id: original.id) == moved)

        let resized = try db.blocks.resize(id: original.id, duration: 1800)
        #expect(resized.start == Fixture.date(day: 17, 13, 15))
        #expect(resized.duration == 1800)
        #expect(try db.blocks.fetch(id: original.id) == resized)
    }

    @Test func blocksOnDayIncludesOverlapsAndSortsByStart() throws {
        let overnight = try block("Overnight", day: 16, 23, 30, minutes: 60)
        let late = try block("Late", 22)
        let early = try block("Early", 6)
        try block("Yesterday", day: 16, 9)
        try block("Tomorrow", day: 18, 0)
        let endsAtMidnight = try block("Ends at midnight", 23, minutes: 60)

        let ids = try db.blocks.blocks(onDayContaining: Fixture.date(day: 17, 12)).map(\.id)
        #expect(ids == [overnight.id, early.id, late.id, endsAtMidnight.id])
    }

    @Test func rangeQueryIsHalfOpenOnBothEnds() throws {
        let before = try block("Before", 8)       // 08:00–09:00, touches range start
        let inside = try block("Inside", 9, 30)   // 09:30–10:30
        let after = try block("After", 11)        // 11:00–12:00, touches range end
        let range = Fixture.date(day: 17, 9)..<Fixture.date(day: 17, 11)

        #expect(try db.blocks.blocks(in: range).map(\.id) == [inside.id])
        #expect(before.end == range.lowerBound)
        #expect(after.start == range.upperBound)
    }

    @Test func emptyRangeMatchesNothing() async throws {
        try block("Spanning", 9)
        let instant = Fixture.date(day: 17, 9, 30)
        #expect(try db.blocks.blocks(in: instant..<instant).isEmpty)

        var iterator = db.blocks.observe(in: instant..<instant).makeAsyncIterator()
        let value = await iterator.next()
        #expect(value == [])
    }

    @Test func equalStartsResolveDeterministicallyByID() throws {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // Insert the eventual winner first so insertion order can't explain the result.
        try db.blocks.insert(TimeBlock(id: high, title: "High", start: Fixture.date(day: 17, 9), duration: 3600))
        try db.blocks.insert(TimeBlock(id: low, title: "Low", start: Fixture.date(day: 17, 9), duration: 3600))

        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 15))?.id == high)
        #expect(try db.blocks.blocks(onDayContaining: Fixture.date(day: 17)).map(\.id) == [low, high])
    }

    @Test func blockAtFindsContainingBlock() throws {
        let b = try block("B", 9, minutes: 30)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 15))?.id == b.id)
    }

    @Test func blockAtIncludesStart() throws {
        let b = try block("B", 9, minutes: 30)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9))?.id == b.id)
    }

    @Test func blockAtExcludesEnd() throws {
        try block("B", 9, minutes: 30)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 30)) == nil)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 30).addingTimeInterval(-0.001)) != nil)
    }

    @Test func blockAtBeforeStartIsNil() throws {
        try block("B", 9, minutes: 30)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9).addingTimeInterval(-0.001)) == nil)
    }

    @Test func blockAtAdjacentBoundaryPicksTheNextBlock() throws {
        try block("First", 9, minutes: 30)
        let second = try block("Second", 9, 30, minutes: 30)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 30))?.id == second.id)
    }

    @Test func blockAtOverlapPrefersMostRecentStart() throws {
        let long = try block("Long", 9, minutes: 180)
        let nested = try block("Nested", 10, minutes: 30)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 10, 15))?.id == nested.id)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 10, 30))?.id == long.id)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 59))?.id == long.id)
    }

    @Test func blockAtSpansMidnight() throws {
        let overnight = try block("Overnight", day: 16, 23, 30, minutes: 60)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 0, 15))?.id == overnight.id)
    }

    @Test func blockAtWithNoBlocksIsNil() throws {
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9)) == nil)
    }

    @Test func blockAtReflectsMoveAndResize() throws {
        let b = try block("B", 9, minutes: 30)
        try db.blocks.move(id: b.id, to: Fixture.date(day: 17, 14))
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 9, 15)) == nil)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 14, 15))?.id == b.id)

        try db.blocks.resize(id: b.id, duration: 3600)
        #expect(try db.blocks.block(at: Fixture.date(day: 17, 14, 45))?.id == b.id)
    }

    @Test func observeDayEmitsChanges() async throws {
        var iterator = db.blocks.observe(onDayContaining: Fixture.date(day: 17)).makeAsyncIterator()
        let value1 = await iterator.next()
        #expect(value1 == [])

        let b = try block("B", 9)
        let value2 = await iterator.next()
        #expect(value2 == [b])

        let moved = try db.blocks.move(id: b.id, to: Fixture.date(day: 18, 9))
        #expect(moved.start == Fixture.date(day: 18, 9))
        let value3 = await iterator.next()
        #expect(value3 == [])
    }
}
