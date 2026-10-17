import AVFoundation
import AppKit
import PomodoroCore
import XCTest
@testable import Pomodoro

/// The ambient library as built into the app: what the player will actually open.
@MainActor
final class AmbientBundleTests: XCTestCase {
    private let bundle = Bundle(for: AppModel.self)
    private var library: AmbientLibrary { .bundled(in: bundle) }

    func testManifestIsBundled() {
        XCTAssertEqual(library.sounds.count, 15)
    }

    func testEverySoundLoadsAndLoopsAtItsManifestLength() throws {
        for sound in library.sounds {
            let url = try XCTUnwrap(AVAmbientEngine.url(for: sound, in: bundle), "\(sound.file) isn't in the bundle")
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.processingFormat.sampleRate, sound.sampleRate, sound.id)
            XCTAssertEqual(Int(file.processingFormat.channelCount), sound.channels, sound.id)
            // Encoder priming or padding left in would put a gap or a click at every loop.
            XCTAssertEqual(Int(file.length), sound.frames, "\(sound.id) doesn't decode to its loop length")
        }
    }

    /// The length above is container metadata; this decodes every frame, a chunk at a time.
    func testEverySoundDecodesEveryFrame() throws {
        for sound in library.sounds {
            let url = try XCTUnwrap(AVAmbientEngine.url(for: sound, in: bundle))
            let file = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16))
            var decoded = 0
            while file.framePosition < file.length {
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                decoded += Int(buffer.frameLength)
            }
            XCTAssertEqual(decoded, sound.frames, sound.id)
        }
    }

    func testEverySymbolExists() {
        for sound in library.sounds {
            XCTAssertNotNil(NSImage(systemSymbolName: sound.symbol, accessibilityDescription: nil), "\(sound.id): \(sound.symbol)")
        }
    }

    func testEveryAttributionLicenseIsCredited() throws {
        let attributed = library.sounds.filter { $0.credit?.license.requiresAttribution == true }
        XCTAssertEqual(Set(attributed.map(\.id)), ["rain", "storm", "waves", "city", "train"])
        for sound in library.sounds where sound.source.kind == .blanket {
            let credit = try XCTUnwrap(sound.credit, "\(sound.id) has no credit")
            XCTAssertFalse(credit.author.isEmpty)
            XCTAssertFalse(credit.title.isEmpty)
        }
    }

    func testFitsTheBundleBudget() throws {
        let directory = try XCTUnwrap(bundle.resourceURL?.appendingPathComponent(AmbientLibrary.resourceSubdirectory))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(total, 12 * 1024 * 1024)
    }
}
