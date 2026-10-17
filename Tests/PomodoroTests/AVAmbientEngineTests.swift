import AVFoundation
import PomodoroCore
import XCTest
@testable import Pomodoro

/// The real engine, which the player tests replace with a fake. AVAudioEngine reports misuse by
/// raising Objective-C exceptions that Swift can't catch, so these fail by crashing.
@MainActor
final class AVAmbientEngineTests: XCTestCase {
    private let bundle = Bundle(for: AppModel.self)

    /// The player starts the engine before it adds the first voice.
    func testStartsBeforeAnyVoiceIsAdded() throws {
        let engine = AVAmbientEngine(bundle: bundle)
        defer { engine.stop() }
        try startOrSkip(engine)
        XCTAssertTrue(engine.isRunning)
    }

    func testPlaysAVoiceThenStops() throws {
        let engine = AVAmbientEngine(bundle: bundle)
        let rain = try XCTUnwrap(AmbientLibrary.bundled(in: bundle).sound(id: "rain"))
        try startOrSkip(engine)
        try engine.addVoice(rain)
        let ramped = expectation(description: "ramp finished")
        engine.ramp(rain.id, to: 0.5, over: 0.05) { ramped.fulfill() }
        wait(for: [ramped], timeout: 2)
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    /// CI runners may have no audio output; that's a thrown error, not a test failure.
    private func startOrSkip(_ engine: AVAmbientEngine) throws {
        do {
            try engine.start()
        } catch AmbientEngineError.noOutputDevice {
            throw XCTSkip("no audio output device")
        }
    }
}
