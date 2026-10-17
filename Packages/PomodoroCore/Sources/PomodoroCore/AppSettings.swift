import Foundation

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Sendable {
    case iconOnly
    case time
    case timeAndTask
}

public struct SoundSettings: Hashable, Sendable {
    public static let volumeRange: ClosedRange<Double> = 0...1

    public var focusEnd: SoundID
    public var breakEnd: SoundID
    public var start: SoundID
    public var tick: SoundID
    public var volume: Double {
        didSet { volume = Self.clampVolume(volume) }
    }

    public init(
        focusEnd: SoundID = .chimeFocusEnd,
        breakEnd: SoundID = .chimeBreakEnd,
        start: SoundID = .start,
        tick: SoundID = .none,
        volume: Double = 0.8
    ) {
        self.focusEnd = focusEnd
        self.breakEnd = breakEnd
        self.start = start
        self.tick = tick
        self.volume = Self.clampVolume(volume)
    }

    public static func clampVolume(_ value: Double) -> Double {
        guard value.isFinite else { return volumeRange.upperBound }
        return min(max(value, volumeRange.lowerBound), volumeRange.upperBound)
    }
}

extension SoundSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case focusEnd, breakEnd, start, tick, volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = SoundSettings()
        self.init(
            focusEnd: c.lenient(SoundID.self, .focusEnd) ?? base.focusEnd,
            breakEnd: c.lenient(SoundID.self, .breakEnd) ?? base.breakEnd,
            start: c.lenient(SoundID.self, .start) ?? base.start,
            tick: c.lenient(SoundID.self, .tick) ?? base.tick,
            volume: c.lenient(Double.self, .volume) ?? base.volume
        )
    }
}

/// Everything the user can configure. Persisted as versioned JSON; decoding is lenient field by
/// field so that data from older builds (or with unknown enum values) keeps whatever it can.
public struct AppSettings: Hashable, Sendable {
    /// Bump when the stored shape changes in a way `init(from:)` can't absorb, and add a step to
    /// `migrate(_:from:)`.
    public static let currentVersion = 1

    public private(set) var presets: [Preset]
    public private(set) var defaultPresetID: Preset.ID
    public var sounds: SoundSettings
    public var menuBarDisplay: MenuBarDisplayMode
    public var launchAtLogin: Bool
    /// 1 = Sunday … 7 = Saturday, matching `Calendar.firstWeekday`. `nil` follows the system.
    public var firstWeekday: Int? {
        didSet { firstWeekday = Self.normalizedWeekday(firstWeekday) }
    }

    public init(
        presets: [Preset] = Preset.builtIns,
        defaultPresetID: Preset.ID = Preset.classic.id,
        sounds: SoundSettings = SoundSettings(),
        menuBarDisplay: MenuBarDisplayMode = .time,
        launchAtLogin: Bool = false,
        firstWeekday: Int? = nil
    ) {
        var seen = Set<Preset.ID>()
        var unique = presets.filter { seen.insert($0.id).inserted }
        for i in unique.indices { unique[i].name = Preset.normalizedName(unique[i].name) }
        if unique.isEmpty { unique = Preset.builtIns }
        self.presets = unique
        self.defaultPresetID = unique.contains { $0.id == defaultPresetID } ? defaultPresetID : unique[0].id
        self.sounds = sounds
        self.menuBarDisplay = menuBarDisplay
        self.launchAtLogin = launchAtLogin
        self.firstWeekday = Self.normalizedWeekday(firstWeekday)
    }

    public static let `default` = AppSettings()

    public var defaultPreset: Preset {
        presets.first { $0.id == defaultPresetID } ?? presets[0]
    }

    public var defaultProfile: TimerProfile { defaultPreset.profile }

    public func preset(id: Preset.ID) -> Preset? {
        presets.first { $0.id == id }
    }

    private static func normalizedWeekday(_ value: Int?) -> Int? {
        guard let value, (1...7).contains(value) else { return nil }
        return value
    }
}

// MARK: - Preset management

extension AppSettings {
    public enum PresetError: Error, Equatable {
        case notFound
        case cannotDeleteLastPreset
    }

    @discardableResult
    public mutating func addPreset(name: String, profile: TimerProfile) -> Preset {
        let preset = Preset(name: Preset.normalizedName(name), profile: profile)
        presets.append(preset)
        return preset
    }

    public mutating func updatePreset(_ preset: Preset) throws(PresetError) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { throw .notFound }
        var updated = preset
        updated.name = Preset.normalizedName(preset.name)
        presets[index] = updated
    }

    /// Deleting the default preset moves the default to the first remaining one.
    public mutating func deletePreset(id: Preset.ID) throws(PresetError) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw .notFound }
        guard presets.count > 1 else { throw .cannotDeleteLastPreset }
        presets.remove(at: index)
        if defaultPresetID == id { defaultPresetID = presets[0].id }
    }

    public mutating func setDefaultPreset(id: Preset.ID) throws(PresetError) {
        guard presets.contains(where: { $0.id == id }) else { throw .notFound }
        defaultPresetID = id
    }

    public mutating func movePreset(fromOffset source: Int, toOffset destination: Int) {
        guard presets.indices.contains(source) else { return }
        let preset = presets.remove(at: source)
        presets.insert(preset, at: min(max(destination, 0), presets.count))
    }

    /// Adds back any built-in the user deleted, keeping their edits to the others.
    public mutating func restoreBuiltInPresets() {
        for builtIn in Preset.builtIns where !presets.contains(where: { $0.id == builtIn.id }) {
            presets.append(builtIn)
        }
    }
}

// MARK: - Coding and migration

extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, presets, defaultPresetID, sounds, menuBarDisplay, launchAtLogin, firstWeekday
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = AppSettings.default
        let presets = (try? c.decodeIfPresent([LenientPreset].self, forKey: .presets))?
            .compactMap(\.preset)
        self.init(
            presets: presets ?? base.presets,
            defaultPresetID: c.lenient(UUID.self, .defaultPresetID) ?? base.defaultPresetID,
            sounds: c.lenient(SoundSettings.self, .sounds) ?? base.sounds,
            menuBarDisplay: c.lenient(MenuBarDisplayMode.self, .menuBarDisplay) ?? base.menuBarDisplay,
            launchAtLogin: c.lenient(Bool.self, .launchAtLogin) ?? base.launchAtLogin,
            firstWeekday: c.lenient(Int.self, .firstWeekday)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(presets, forKey: .presets)
        try c.encode(defaultPresetID, forKey: .defaultPresetID)
        try c.encode(sounds, forKey: .sounds)
        try c.encode(menuBarDisplay, forKey: .menuBarDisplay)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(firstWeekday, forKey: .firstWeekday)
    }

    public struct Decoded: Sendable {
        public let settings: AppSettings
        /// The version found in the data; 0 when it predates versioning, `nil` when unreadable.
        public let storedVersion: Int?

        /// True when the data should be rewritten in the current format. Data from a newer build
        /// is left alone so a downgrade doesn't clobber it.
        public var needsResave: Bool {
            guard let storedVersion else { return false }
            return storedVersion < AppSettings.currentVersion
        }
    }

    /// Decodes stored settings, migrating older versions. Unreadable data yields defaults.
    public static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data),
            let settings = try? decoder.decode(AppSettings.self, from: data)
        else {
            return Decoded(settings: .default, storedVersion: nil)
        }
        let version = probe.version ?? 0
        return Decoded(settings: migrate(settings, from: version), storedVersion: version)
    }

    static func migrate(_ settings: AppSettings, from version: Int) -> AppSettings {
        // Version 0 (unversioned) and 1 share a shape; lenient decoding already filled any gaps.
        settings
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private struct VersionProbe: Decodable {
        let version: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = c.lenient(Int.self, .version)
        }
    }
}

/// Drops a single malformed preset instead of failing the whole array.
private struct LenientPreset: Decodable {
    let preset: Preset?

    init(from decoder: Decoder) throws {
        preset = try? Preset(from: decoder)
    }
}
