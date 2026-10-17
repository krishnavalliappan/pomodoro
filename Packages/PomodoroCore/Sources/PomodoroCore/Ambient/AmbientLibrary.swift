import Foundation

/// The bundled ambient sounds, as listed in `ambient-credits.json` by `scripts/import_ambient.py`.
public struct AmbientLibrary: Decodable, Hashable, Sendable {
    public static let manifestName = "ambient-credits"
    public static let resourceSubdirectory = "Ambient"

    public let version: Int
    public let sounds: [AmbientSound]

    public init(version: Int = 1, sounds: [AmbientSound]) {
        self.version = version
        self.sounds = sounds
    }

    public static let empty = AmbientLibrary(sounds: [])

    public static func decode(_ data: Data) throws -> AmbientLibrary {
        try JSONDecoder().decode(AmbientLibrary.self, from: data)
    }

    public var ids: Set<AmbientSound.ID> { Set(sounds.map(\.id)) }

    public func sound(id: AmbientSound.ID) -> AmbientSound? {
        sounds.first { $0.id == id }
    }

    /// Sounds whose license asks for a credit, which the app must show.
    public var attributed: [AmbientSound] {
        sounds.filter { $0.credit?.license.requiresAttribution == true }
    }
}

public struct AmbientSound: Decodable, Hashable, Sendable, Identifiable {
    public typealias ID = AmbientMix.SoundID

    public let id: ID
    public let title: String
    /// An SF Symbol name.
    public let symbol: String
    public let file: String
    /// The loop's exact length; it repeats from frame 0 straight after the last one.
    public let frames: Int
    public let sampleRate: Double
    public let channels: Int
    public let duration: TimeInterval
    public let source: AmbientSource
    /// `nil` for sounds generated in this repo.
    public let credit: AmbientCredit?

    public init(
        id: ID, title: String, symbol: String, file: String, frames: Int, sampleRate: Double = 44_100,
        channels: Int = 2, duration: TimeInterval, source: AmbientSource, credit: AmbientCredit?
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.file = file
        self.frames = frames
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = duration
        self.source = source
        self.credit = credit
    }

    public var fileExtension: String { (file as NSString).pathExtension }
    public var fileBaseName: String { (file as NSString).deletingPathExtension }
}

public struct AmbientSource: Decodable, Hashable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case blanket
        case generated
    }

    public let kind: Kind
    public let commit: String?
    public let path: String?
    public let url: URL?
    public let sha256: String?

    public init(kind: Kind, commit: String? = nil, path: String? = nil, url: URL? = nil, sha256: String? = nil) {
        self.kind = kind
        self.commit = commit
        self.path = path
        self.url = url
        self.sha256 = sha256
    }
}

public struct AmbientCredit: Decodable, Hashable, Sendable {
    /// The original recording's title on its source page.
    public let title: String
    public let author: String
    public let url: URL
    public let license: AmbientLicense
    public let licenseName: String
    public let licenseURL: URL?
    public let editedBy: String?

    public init(
        title: String, author: String, url: URL, license: AmbientLicense, licenseName: String,
        licenseURL: URL? = nil, editedBy: String? = nil
    ) {
        self.title = title
        self.author = author
        self.url = url
        self.license = license
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.editedBy = editedBy
    }
}

/// Only licenses that allow bundling without share-alike terms. An unknown value fails to decode
/// on purpose, so a sound under any other license can't slip into the manifest.
public enum AmbientLicense: String, Decodable, Sendable, CaseIterable {
    case cc0 = "CC0-1.0"
    case publicDomain = "PD"
    case ccBy3 = "CC-BY-3.0"
    case ccBy4 = "CC-BY-4.0"
    case original

    public var requiresAttribution: Bool {
        switch self {
        case .ccBy3, .ccBy4: true
        case .cc0, .publicDomain, .original: false
        }
    }
}
