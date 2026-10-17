import Foundation

/// The engine reads time through this so tests (and sleep/wake reconciliation) can control it.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock that only moves when told to. Shared by reference so a test and the engine see the same time.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        current = now
    }

    public var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}
