import Foundation

public protocol SettingsStore: AnyObject, Sendable {
    func load() -> AppSettings
    /// Throws `SettingsStoreError.newerVersionStored` instead of overwriting data written by a
    /// newer build; the stored bytes are left untouched so upgrading again loses nothing.
    func save(_ settings: AppSettings) throws
}

public enum SettingsStoreError: Error, Equatable, LocalizedError {
    case newerVersionStored(Int)

    public var errorDescription: String? {
        switch self {
        case .newerVersionStored:
            "These settings were saved by a newer version of Pomodoro and can't be changed here."
        }
    }
}

/// UserDefaults is thread-safe, which is why the unchecked conformance is sound.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let defaultKey = "appSettings"

    private let defaults: UserDefaults
    private let key: String
    // Keeps the version check and the write it guards atomic within this process.
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return .default }
            let decoded = AppSettings.decode(data)
            if decoded.needsResave {
                try? write(decoded.settings)
            }
            return decoded.settings
        }
    }

    public func save(_ settings: AppSettings) throws {
        try lock.withLock { try write(settings) }
    }

    private func write(_ settings: AppSettings) throws {
        if let data = defaults.data(forKey: key),
            let stored = AppSettings.storedVersion(in: data), stored > AppSettings.currentVersion
        {
            throw SettingsStoreError.newerVersionStored(stored)
        }
        defaults.set(try settings.encoded(), forKey: key)
    }
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AppSettings

    public init(_ settings: AppSettings = .default) {
        self.settings = settings
    }

    public func load() -> AppSettings {
        lock.withLock { settings }
    }

    public func save(_ settings: AppSettings) throws {
        lock.withLock { self.settings = settings }
    }
}
