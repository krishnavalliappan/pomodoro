import Foundation

/// The ambient sounds layered during focus, each at its own level, under one master volume.
///
/// Ids are the library manifest's, kept as plain strings so a sound leaving the library never
/// makes stored settings unreadable; `restricted(to:)` drops the ones it no longer has.
public struct AmbientMix: Hashable, Sendable {
    public typealias SoundID = String

    public static let volumeRange: ClosedRange<Double> = 0...1
    /// Past this many layers a mix turns to mush, and each layer decodes in real time.
    public static let maxLayers = 4
    public static let defaultVolume = 0.6
    public static let defaultLevel = 1.0

    /// Playing sounds, oldest first, without duplicates.
    public private(set) var sounds: [SoundID]
    /// Levels the user changed. A sound switched off keeps its level for when it comes back.
    public private(set) var levels: [SoundID: Double]
    public var volume: Double {
        didSet { volume = Self.clamp(volume) }
    }

    public init(sounds: [SoundID] = [], levels: [SoundID: Double] = [:], volume: Double = AmbientMix.defaultVolume) {
        var seen = Set<SoundID>()
        let unique = sounds.filter { seen.insert($0).inserted }
        self.sounds = Array(unique.suffix(Self.maxLayers))
        self.levels = levels.compactMapValues { $0.isFinite ? Self.clamp($0) : nil }.filter { $0.value != Self.defaultLevel }
        self.volume = Self.clamp(volume)
    }

    public var isEmpty: Bool { sounds.isEmpty }

    public func contains(_ id: SoundID) -> Bool {
        sounds.contains(id)
    }

    public func level(for id: SoundID) -> Double {
        levels[id] ?? Self.defaultLevel
    }

    /// What the sound plays at: its level under the master volume, or 0 when it's off.
    public func volume(for id: SoundID) -> Double {
        contains(id) ? volume * level(for: id) : 0
    }

    /// Switching on a sound past `maxLayers` drops the oldest one.
    public mutating func toggle(_ id: SoundID) {
        setActive(id, !contains(id))
    }

    public mutating func setActive(_ id: SoundID, _ active: Bool) {
        if active {
            guard !contains(id) else { return }
            sounds.append(id)
            if sounds.count > Self.maxLayers { sounds.removeFirst(sounds.count - Self.maxLayers) }
        } else {
            sounds.removeAll { $0 == id }
        }
    }

    public mutating func setLevel(_ level: Double, for id: SoundID) {
        let level = level.isFinite ? Self.clamp(level) : Self.defaultLevel
        levels[id] = level == Self.defaultLevel ? nil : level
    }

    /// Without the sounds a library doesn't have, e.g. after an update removed one.
    public func restricted(to known: Set<SoundID>) -> AmbientMix {
        AmbientMix(sounds: sounds.filter(known.contains), levels: levels.filter { known.contains($0.key) }, volume: volume)
    }

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultVolume }
        return min(max(value, volumeRange.lowerBound), volumeRange.upperBound)
    }
}

extension AmbientMix: Codable {
    private enum CodingKeys: String, CodingKey {
        case sounds, levels, volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sounds: c.lenient([SoundID].self, .sounds) ?? [],
            levels: c.lenient([SoundID: Double].self, .levels) ?? [:],
            volume: c.lenient(Double.self, .volume) ?? Self.defaultVolume
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sounds, forKey: .sounds)
        try c.encode(levels, forKey: .levels)
        try c.encode(volume, forKey: .volume)
    }
}
