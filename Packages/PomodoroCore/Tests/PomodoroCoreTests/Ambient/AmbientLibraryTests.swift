import Foundation
import Testing
@testable import PomodoroCore

/// Checks the committed library in `App/Resources/Ambient`, which `scripts/import_ambient.py`
/// writes. The app tests check the same files load from the built bundle.
struct AmbientLibraryTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Ambient
        .deletingLastPathComponent() // PomodoroCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PomodoroCore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("App/Resources/Ambient", isDirectory: true)

    static let budget = 12 * 1024 * 1024

    private func library() throws -> AmbientLibrary {
        let url = Self.directory.appendingPathComponent("\(AmbientLibrary.manifestName).json")
        return try AmbientLibrary.decode(Data(contentsOf: url))
    }

    @Test func listsTheAgreedSounds() throws {
        let ids = try library().sounds.map(\.id)
        #expect(ids == [
            "forest", "rain", "storm", "wind", "waves", "stream", "night", "fireplace", "cafe", "city", "train", "boat",
            "white-noise", "pink-noise", "brown-noise",
        ])
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyEntryHasItsFileAndALoopableLength() throws {
        for sound in try library().sounds {
            let url = Self.directory.appendingPathComponent(sound.file)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(sound.file) is missing")
            #expect(sound.fileExtension == "m4a")
            #expect(sound.frames > Int(sound.sampleRate) * 4, "\(sound.id) loops too often to be unnoticeable")
            #expect(abs(Double(sound.frames) / sound.sampleRate - sound.duration) < 0.001)
            #expect(!sound.title.isEmpty && !sound.symbol.isEmpty)
        }
    }

    @Test func recordingsArePinnedAndCredited() throws {
        for sound in try library().sounds {
            switch sound.source.kind {
            case .blanket:
                #expect(sound.source.commit?.count == 40, "\(sound.id) isn't pinned to a commit")
                #expect(sound.source.sha256?.count == 64, "\(sound.id) has no source hash")
                let credit = try #require(sound.credit, "\(sound.id) has no credit")
                #expect(credit.license != .original)
                #expect(!credit.author.isEmpty)
                #expect(["freesound.org", "soundbible.com"].contains(credit.url.host ?? ""), "\(sound.id): \(credit.url)")
            case .generated:
                #expect(sound.credit == nil)
            }
        }
    }

    @Test func everyAttributionLicenseHasACredit() throws {
        let library = try library()
        #expect(library.attributed.count == 5, "rain, storm, waves, city and train are CC BY")
        for sound in library.attributed {
            let credit = try #require(sound.credit)
            #expect(!credit.author.isEmpty && !credit.title.isEmpty)
            #expect(credit.licenseURL?.host == "creativecommons.org")
        }
    }

    @Test func noShareAlikeOrUnknownLicenses() throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("\(AmbientLibrary.manifestName).json"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("BY-SA") && !text.contains("BY SA"))
        // Decoding fails on any license outside AmbientLicense, so reaching here proves the rest.
        _ = try library()
    }

    @Test func staysWithinTheBundleBudget() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(total > 0)
        #expect(total <= Self.budget, "ambient library is \(total) bytes")
    }

    @Test func unknownLicenseFailsToDecode() {
        let json = #"""
            {"version": 1, "sounds": [{"id": "x", "title": "X", "symbol": "x", "file": "x.m4a", "frames": 1,
              "sampleRate": 44100, "channels": 2, "duration": 0, "source": {"kind": "blanket"},
              "credit": {"title": "x", "author": "a", "url": "https://freesound.org/x", "license": "CC-BY-SA-4.0",
                         "licenseName": "CC BY-SA 4.0"}}]}
            """#
        #expect(throws: DecodingError.self) { try AmbientLibrary.decode(Data(json.utf8)) }
    }

    @Test func licensesThatNeedCredit() {
        #expect(AmbientLicense.allCases.filter(\.requiresAttribution) == [.ccBy3, .ccBy4])
    }
}
