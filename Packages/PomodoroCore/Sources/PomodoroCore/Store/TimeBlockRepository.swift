import Foundation
import GRDB

public struct TimeBlockRepository: Sendable {
    let database: AppDatabase

    private var writer: any DatabaseWriter { database.writer }

    public func insert(_ block: TimeBlock) throws {
        try Self.validate(duration: block.duration)
        try writer.write { db in try block.insert(db) }
    }

    public func update(_ block: TimeBlock) throws {
        try Self.validate(duration: block.duration)
        try writer.write { db in
            do {
                try block.update(db)
            } catch RecordError.recordNotFound {
                throw StoreError.notFound(block.id)
            }
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try writer.write { db in try TimeBlock.deleteOne(db, key: id) }
    }

    public func fetch(id: UUID) throws -> TimeBlock? {
        try writer.read { db in try TimeBlock.fetchOne(db, key: id) }
    }

    @discardableResult
    public func move(id: UUID, to start: Date) throws -> TimeBlock {
        try modify(id: id) { $0.start = start }
    }

    @discardableResult
    public func resize(id: UUID, duration: TimeInterval) throws -> TimeBlock {
        try Self.validate(duration: duration)
        return try modify(id: id) { $0.duration = duration }
    }

    /// Blocks that overlap `range` at all, ordered by start.
    public func blocks(in range: Range<Date>) throws -> [TimeBlock] {
        try writer.read { db in try Self.overlapping(range).fetchAll(db) }
    }

    public func blocks(onDayContaining date: Date) throws -> [TimeBlock] {
        try blocks(in: database.dayRange(containing: date))
    }

    /// The block containing `date` (start inclusive, end exclusive). When blocks
    /// overlap, the one that started most recently wins.
    public func block(at date: Date) throws -> TimeBlock? {
        try writer.read { db in try Self.containing(date).fetchOne(db) }
    }

    public func observe(in range: Range<Date>) -> AsyncStream<[TimeBlock]> {
        database.observe { db in try Self.overlapping(range).fetchAll(db) }
    }

    public func observe(onDayContaining date: Date) -> AsyncStream<[TimeBlock]> {
        observe(in: database.dayRange(containing: date))
    }

    // MARK: - Private

    private static var end: SQLExpression { TimeBlock.Columns.start + TimeBlock.Columns.duration }

    private static func overlapping(_ range: Range<Date>) -> QueryInterfaceRequest<TimeBlock> {
        TimeBlock
            .filter(TimeBlock.Columns.start < range.upperBound.sqlValue && end > range.lowerBound.sqlValue)
            .order(TimeBlock.Columns.start, TimeBlock.Columns.duration)
    }

    private static func containing(_ date: Date) -> QueryInterfaceRequest<TimeBlock> {
        TimeBlock
            .filter(TimeBlock.Columns.start <= date.sqlValue && end > date.sqlValue)
            .order(TimeBlock.Columns.start.desc)
            .limit(1)
    }

    private static func validate(duration: TimeInterval) throws {
        guard duration > 0, duration.isFinite else { throw StoreError.invalidDuration(duration) }
    }

    private func modify(id: UUID, _ change: @Sendable (inout TimeBlock) -> Void) throws -> TimeBlock {
        try writer.write { db in
            guard var block = try TimeBlock.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            change(&block)
            try block.update(db)
            return block
        }
    }
}
