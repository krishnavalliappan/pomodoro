import Foundation

/// The engine state plus the profile the session in progress runs on, which differs from the
/// default after a one-off override. Saved so a running session survives a relaunch.
public struct PersistedTimer: Codable, Equatable, Sendable {
    public var state: TimerState
    public var profile: TimerProfile

    public init(state: TimerState, profile: TimerProfile) {
        self.state = state
        self.profile = profile
    }
}

public protocol TimerStateStore: AnyObject, Sendable {
    /// `nil` when nothing was saved or the data can't be read; the app then starts idle.
    func load() -> PersistedTimer?
    func save(_ timer: PersistedTimer) throws
}

/// UserDefaults is thread-safe, which is why the unchecked conformance is sound.
public final class UserDefaultsTimerStateStore: TimerStateStore, @unchecked Sendable {
    public static let defaultKey = "timerState"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsTimerStateStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PersistedTimer? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedTimer.self, from: data)
    }

    public func save(_ timer: PersistedTimer) throws {
        defaults.set(try JSONEncoder().encode(timer), forKey: key)
    }
}

public final class InMemoryTimerStateStore: TimerStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var timer: PersistedTimer?

    public init(_ timer: PersistedTimer? = nil) {
        self.timer = timer
    }

    public func load() -> PersistedTimer? {
        lock.withLock { timer }
    }

    public func save(_ timer: PersistedTimer) throws {
        lock.withLock { self.timer = timer }
    }
}
