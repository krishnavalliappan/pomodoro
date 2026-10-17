import AVFoundation
import XCTest
@testable import Pomodoro

@MainActor
final class SoundServiceTests: XCTestCase {
    private var appBundle: Bundle { Bundle(for: SoundService.self) }

    func testEverySoundResourceExistsAndLoads() throws {
        for sound in AppSound.allCases where sound != .none {
            let url = try XCTUnwrap(SoundService.url(for: sound, in: appBundle), "missing resource for \(sound)")
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertGreaterThan(player.duration, 0, "\(sound) has no audio")
            XCTAssertEqual(player.format.sampleRate, 44_100, "\(sound)")
        }
    }

    func testNoneHasNoResource() {
        XCTAssertNil(SoundService.url(for: .none, in: appBundle))
    }

    func testPreloadsEverySound() {
        let service = SoundService(bundle: appBundle)
        for sound in AppSound.allCases where sound != .none {
            XCTAssertTrue(service.isLoaded(sound), "\(sound) not preloaded")
        }
        XCTAssertFalse(service.isLoaded(.none))
    }

    func testTickDurationIsShort() throws {
        let url = try XCTUnwrap(SoundService.url(for: .tick, in: appBundle))
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertLessThan(player.duration, 0.1)
    }

    func testMasterVolumeIsClamped() {
        let service = SoundService(bundle: appBundle, masterVolume: 2)
        XCTAssertEqual(service.masterVolume, 1)
        service.masterVolume = -1
        XCTAssertEqual(service.masterVolume, 0)
    }

    func testTickIsOffByDefaultAndOnlyRunsWhenEnabled() {
        let service = SoundService(bundle: appBundle)
        service.startTicking()
        XCTAssertFalse(service.isTicking)

        service.tickEnabled = true
        service.startTicking()
        XCTAssertTrue(service.isTicking)
        service.stopTicking()
        XCTAssertFalse(service.isTicking)

        service.startTicking()
        service.tickEnabled = false
        XCTAssertFalse(service.isTicking)
    }

    func testChoosingNoneIsSilent() {
        let service = SoundService(bundle: appBundle, choices: [.focusEnd: .none])
        service.play(for: .focusEnd)
        service.play(for: .breakEnd)
    }
}
