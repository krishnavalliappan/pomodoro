import Foundation

public protocol SettingsStore: AnyObject, Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings) throws
}

/// UserDefaults is thread-safe, which is why the unchecked conformance is sound.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let defaultKey = "appSettings"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsSettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return .default }
        let decoded = AppSettings.decode(data)
        if decoded.needsResave {
            try? save(decoded.settings)
        }
        return decoded.settings
    }

    public func save(_ settings: AppSettings) throws {
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
