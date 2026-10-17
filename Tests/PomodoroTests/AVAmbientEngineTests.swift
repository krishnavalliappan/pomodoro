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

    // MARK: Waiting for an output

    func testNoOutputWaitsForOneThenStartsTheMixAgain() throws {
        try XCTSkipUnless(AVAmbientEngine.hasUsableOutput(AVAudioEngine()), "no audio output device")
        let monitor = FakeOutputMonitor()
        let output = OutputSwitch()
        let engine = AVAmbientEngine(bundle: bundle, outputMonitor: monitor) { output.isOn && AVAmbientEngine.hasUsableOutput($0) }
        let clock = TestClock(now: ModelHarness.start)
        let player = AmbientPlayer(
            library: .bundled(in: bundle), engine: engine, scheduler: FakeScheduler(clock: clock), clock: clock,
            mix: AmbientMix(sounds: ["rain"]))
        defer { player.shutdown() }

        player.update(phase: .focus, status: .running)
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(engine.isWaitingForOutput)
        XCTAssertTrue(monitor.isWatching)

        output.isOn = true
        monitor.change()
        XCTAssertTrue(engine.isRunning, "back without any change to the timer or the mix")
        XCTAssertTrue(player.isAudible)
        XCTAssertFalse(monitor.isWatching)
    }

    func testStopsWaitingOnceNothingShouldPlay() {
        let monitor = FakeOutputMonitor()
        let engine = AVAmbientEngine(bundle: bundle, outputMonitor: monitor) { _ in false }
        let clock = TestClock(now: ModelHarness.start)
        let player = AmbientPlayer(
            library: .bundled(in: bundle), engine: engine, scheduler: FakeScheduler(clock: clock), clock: clock,
            mix: AmbientMix(sounds: ["rain"]))

        player.update(phase: .focus, status: .running)
        XCTAssertTrue(monitor.isWatching)
        player.update(phase: .focus, status: .paused)
        XCTAssertFalse(monitor.isWatching)
        XCTAssertFalse(engine.isWaitingForOutput)
    }

    // MARK: Looping

    /// A loop far shorter than any in the library, rendered offline across many seams: every
    /// frame carries signal, so no pass was late, and refilling from AVFAudio's queue never
    /// deadlocks against the main actor.
    func testShortLoopRefillsWithoutAGap() async throws {
        let frames: AVAudioFrameCount = 2048
        let rig = try OfflineLoop(url: try Self.constantFile(frames: frames))
        let passes = 20
        for _ in 0..<(passes * 2) {
            try await rig.render(frames / 2)
        }
        XCTAssertEqual(rig.silentFrames, 0, "a gap at a seam")
        // The node reads ahead of what it renders, so more than two may be queued by now.
        XCTAssertGreaterThanOrEqual(rig.loop.passesQueued, passes + 2, "two passes always queued ahead")
    }

    /// A pass consumed while the voice is being removed must not queue another on a stopped node.
    func testStoppingWithAPassPendingQueuesNoMore() async throws {
        let frames: AVAudioFrameCount = 2048
        let rig = try OfflineLoop(url: try Self.constantFile(frames: frames))
        try await rig.render(frames + frames / 2)
        let queued = rig.loop.passesQueued
        rig.loop.stop()
        rig.node.stop()
        rig.engine.detach(rig.node)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.loop.passesQueued, queued)
    }

    /// CI runners may have no audio output; that's a thrown error, not a test failure.
    private func startOrSkip(_ engine: AVAmbientEngine) throws {
        do {
            try engine.start()
        } catch AmbientEngineError.noOutputDevice {
            throw XCTSkip("no audio output device")
        }
    }

    /// Every sample 0.25, so silence in the output can only be a gap.
    private static func constantFile(frames: AVAudioFrameCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) { samples[frame] = 0.25 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// A `SeamlessLoop` on a player node in an engine that renders on demand, with no device.
@MainActor
private final class OfflineLoop {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let loop: SeamlessLoop
    private let buffer: AVAudioPCMBuffer
    private let fileFrames: Int
    private var rendered = 0
    private(set) var silentFrames = 0

    init(url: URL) throws {
        loop = try SeamlessLoop(url: url)
        fileFrames = Int(try AVAudioFile(forReading: url).length)
        try engine.enableManualRenderingMode(.offline, format: loop.format, maximumFrameCount: 4096)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: loop.format)
        try engine.start()
        buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        loop.start(on: node)
        node.play()
    }

    /// Renders, then waits for the refills that what was rendered should have triggered.
    func render(_ frames: AVAudioFrameCount) async throws {
        XCTAssertEqual(try engine.renderOffline(frames, to: buffer), .success)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        silentFrames += (0..<Int(buffer.frameLength)).filter { abs(samples[$0]) < 0.1 }.count
        rendered += Int(buffer.frameLength)
        let due = rendered / fileFrames + 2
        let deadline = ContinuousClock.now + .seconds(5)
        while loop.passesQueued < due {
            XCTAssertLessThan(ContinuousClock.now, deadline, "refill never arrived")
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
final class FakeOutputMonitor: AudioOutputMonitor {
    private var onChange: (@MainActor () -> Void)?
    var isWatching: Bool { onChange != nil }

    func start(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func change() {
        onChange?()
    }
}

@MainActor
private final class OutputSwitch {
    var isOn = false
}
