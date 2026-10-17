import AVFoundation
import Foundation
import PomodoroCore
import os

/// The audio side of `AmbientPlayer`: one looping voice per sound, each with its own volume.
/// A protocol so the player's state machine is tested against a fake.
@MainActor
protocol AmbientAudioEngine: AnyObject {
    var isRunning: Bool { get }
    /// Called after the output device or its format changed. The engine has stopped and dropped
    /// every voice by then; the player starts again from scratch.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }

    func start() throws
    /// Stops output and drops every voice, so nothing is left running.
    func stop()
    /// Starts looping the sound, silent until a ramp raises it.
    func addVoice(_ sound: AmbientSound) throws
    func removeVoice(_ id: AmbientSound.ID)
    /// Moves a voice to `volume` over `duration`, then calls `completion`. A newer ramp on the same
    /// voice replaces this one, whose completion then never runs.
    func ramp(_ id: AmbientSound.ID, to volume: Float, over duration: TimeInterval, completion: @escaping @MainActor () -> Void)
}

enum AmbientEngineError: Error {
    case missingFile(String)
    case noOutputDevice
}

@MainActor
final class AVAmbientEngine: AmbientAudioEngine {
    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "ambient")
    /// About one display frame: steps this small don't zipper.
    static let rampStep: Duration = .milliseconds(15)

    var onConfigurationChange: (@MainActor () -> Void)?

    private let bundle: Bundle
    /// Made on start and released on stop, so an unused ambient feature costs nothing.
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var voices: [AmbientSound.ID: Voice] = [:]

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        let engine = self.engine ?? makeEngine()
        guard !engine.isRunning else { return }
        // AVAudioEngine raises an uncatchable exception, rather than throwing, when it has no
        // usable output or nothing wired to it, and voices only arrive after it has started.
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.channelCount > 0, output.sampleRate > 0 else {
            stop()
            throw AmbientEngineError.noOutputDevice
        }
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        for id in Array(voices.keys) { removeVoice(id) }
        engine?.stop()
        engine = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func addVoice(_ sound: AmbientSound) throws {
        guard voices[sound.id] == nil else { return }
        guard let engine else { return }
        guard let url = Self.url(for: sound, in: bundle) else { throw AmbientEngineError.missingFile(sound.file) }
        let loop = try SeamlessLoop(url: url)
        let node = AVAudioPlayerNode()
        node.volume = 0
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: loop.format)
        loop.start(on: node)
        node.play()
        voices[sound.id] = Voice(node: node, loop: loop)
    }

    func removeVoice(_ id: AmbientSound.ID) {
        guard let voice = voices.removeValue(forKey: id) else { return }
        voice.ramp?.cancel()
        voice.loop.stop()
        voice.node.stop()
        engine?.detach(voice.node)
    }

    func ramp(_ id: AmbientSound.ID, to volume: Float, over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard let voice = voices[id] else { return completion() }
        voice.ramp?.cancel()
        let from = voice.node.volume
        guard duration > 0, from != volume else {
            voice.node.volume = volume
            voice.ramp = nil
            return completion()
        }
        let node = voice.node
        voice.ramp = Task { @MainActor in
            let clock = ContinuousClock()
            let begin = clock.now
            let total = Duration.seconds(duration)
            while true {
                try? await clock.sleep(for: Self.rampStep)
                if Task.isCancelled { return }
                let t = min((clock.now - begin) / total, 1)
                // Raised cosine: no corner at either end, which a linear ramp makes audible.
                node.volume = from + (volume - from) * Float((1 - cos(.pi * t)) / 2)
                if t >= 1 { break }
            }
            completion()
        }
    }

    static func url(for sound: AmbientSound, in bundle: Bundle) -> URL? {
        bundle.url(forResource: sound.fileBaseName, withExtension: sound.fileExtension, subdirectory: AmbientLibrary.resourceSubdirectory)
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        return engine
    }

    private func configurationChanged() {
        Self.log.info("audio configuration changed, restarting ambient sounds")
        stop()
        onConfigurationChange?()
    }

    private final class Voice {
        let node: AVAudioPlayerNode
        let loop: SeamlessLoop
        var ramp: Task<Void, Never>?

        init(node: AVAudioPlayerNode, loop: SeamlessLoop) {
            self.node = node
            self.loop = loop
        }
    }
}

/// Streams a file on repeat with no gap: two passes are always queued, and each one that the node
/// has consumed queues the next. The player node joins queued segments sample-accurately, and
/// the library's loops are cut to run end-to-start, so the seam is inaudible.
///
/// Streaming, not a looping PCM buffer: a two-minute stereo loop decodes to over 40 MB.
///
/// `@unchecked Sendable` because the node calls back on its own thread; `lock` guards `isStopped`,
/// and scheduling on a player node is thread-safe.
private final class SeamlessLoop: @unchecked Sendable {
    /// Two handles, alternated, so no pass shares a read position with the one queued behind it.
    private let files: [AVAudioFile]
    private let lock = NSLock()
    private var isStopped = false
    private var passes = 0
    private weak var node: AVAudioPlayerNode?

    init(url: URL) throws {
        files = [try AVAudioFile(forReading: url), try AVAudioFile(forReading: url)]
    }

    var format: AVAudioFormat { files[0].processingFormat }

    func start(on node: AVAudioPlayerNode) {
        self.node = node
        queueNext()
        queueNext()
    }

    func stop() {
        lock.withLock { isStopped = true }
    }

    private func queueNext() {
        let file: AVAudioFile? = lock.withLock {
            guard !isStopped else { return nil }
            passes += 1
            return files[passes % files.count]
        }
        guard let file, let node else { return }
        node.scheduleSegment(
            file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil,
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            self?.queueNext()
        }
    }
}
