import AVFoundation
import CoreAudio
import Foundation
import PomodoroCore
import os

/// The audio side of `AmbientPlayer`: one looping voice per sound, each with its own volume.
/// A protocol so the player's state machine is tested against a fake.
@MainActor
protocol AmbientAudioEngine: AnyObject {
    var isRunning: Bool { get }
    /// A start found no usable output, and the engine is watching for one; `stop()` gives up.
    var isWaitingForOutput: Bool { get }
    /// Called after the output device or its format changed. The engine has stopped and dropped
    /// every voice by then; the player starts again from scratch.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }

    func start() throws
    /// Stops output, drops every voice and stops waiting for output, so nothing is left running.
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
    private(set) var isWaitingForOutput = false

    private let bundle: Bundle
    private let outputMonitor: any AudioOutputMonitor
    private let hasOutput: @MainActor (AVAudioEngine) -> Bool
    /// Made on start and released on stop, so an unused ambient feature costs nothing.
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var voices: [AmbientSound.ID: Voice] = [:]

    init(
        bundle: Bundle = .main,
        outputMonitor: any AudioOutputMonitor = DefaultOutputMonitor(),
        hasOutput: @escaping @MainActor (AVAudioEngine) -> Bool = AVAmbientEngine.hasUsableOutput
    ) {
        self.bundle = bundle
        self.outputMonitor = outputMonitor
        self.hasOutput = hasOutput
    }

    /// AVAudioEngine raises an uncatchable exception, rather than throwing, when it starts
    /// without an output to render to.
    static func hasUsableOutput(_ engine: AVAudioEngine) -> Bool {
        let output = engine.outputNode.outputFormat(forBus: 0)
        return output.channelCount > 0 && output.sampleRate > 0
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        let engine = self.engine ?? makeEngine()
        guard !engine.isRunning else { return }
        guard hasOutput(engine) else {
            waitForOutput()
            throw AmbientEngineError.noOutputDevice
        }
        // Voices arrive after the start; without the mixer wired to the output, `prepare()`
        // raises an exception too.
        _ = engine.mainMixerNode
        engine.prepare()
        do {
            try engine.start()
        } catch {
            waitForOutput()
            throw error
        }
    }

    func stop() {
        for id in Array(voices.keys) { removeVoice(id) }
        engine?.stop()
        engine = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        outputMonitor.stop()
        isWaitingForOutput = false
    }

    /// The engine and its configuration observer are gone with the failed start, so an output
    /// coming back is heard from the system instead; the player then starts again.
    private func waitForOutput() {
        stop()
        isWaitingForOutput = true
        outputMonitor.start { [weak self] in
            guard let self, isWaitingForOutput else { return }
            stop()
            onConfigurationChange?()
        }
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
        let id = ObjectIdentifier(engine)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Releasing an engine inside its own configuration notification can deadlock, so the
            // restart waits a turn; by then the engine may already have been replaced.
            Task { @MainActor in self?.configurationChanged(engine: id) }
        }
        return engine
    }

    private func configurationChanged(engine id: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == id else { return }
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
/// Main-actor bound like every other call on the node: AVFAudio reports a consumed pass on its own
/// queue, and scheduling from there while the main actor plays, stops or detaches the node can
/// deadlock inside AVFAudio. The shortest loop is several seconds, so the hop costs nothing.
@MainActor
final class SeamlessLoop {
    /// Two handles, alternated, so no pass shares a read position with the one queued behind it.
    private let files: [AVAudioFile]
    private var isStopped = false
    private weak var node: AVAudioPlayerNode?
    private(set) var passesQueued = 0

    init(url: URL) throws {
        files = [try AVAudioFile(forReading: url), try AVAudioFile(forReading: url)]
    }

    var format: AVAudioFormat { files[0].processingFormat }

    func start(on node: AVAudioPlayerNode) {
        self.node = node
        queueNext()
        queueNext()
    }

    /// Before the node stops: stopping reports every queued pass as consumed.
    func stop() {
        isStopped = true
    }

    private func queueNext() {
        guard !isStopped, let node, node.engine != nil else { return }
        passesQueued += 1
        let file = files[passesQueued % files.count]
        node.scheduleSegment(
            file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil,
            completionCallbackType: .dataConsumed
        ) { [weak self] _ in
            Task { @MainActor in self?.queueNext() }
        }
    }
}

/// Reports changes to the system's audio outputs, so a start that found none can try again.
@MainActor
protocol AudioOutputMonitor: AnyObject {
    /// Calls `onChange` on the main actor, a turn after each change, until `stop()`.
    func start(_ onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Listens for the default output device or the device list changing, e.g. headphones plugged in.
///
/// A C callback with a fixed context, not a listener block: Swift bridges a closure to a new block
/// at every call, so removing "the same" block removes nothing and the listener lives on.
@MainActor
final class DefaultOutputMonitor: AudioOutputMonitor {
    private static let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]

    /// The callback's context. It lives as long as the monitor, so a change reported while the
    /// listener is being removed never reaches a freed object.
    final class Relay: @unchecked Sendable {
        @MainActor fileprivate var onChange: (@MainActor () -> Void)?

        @MainActor fileprivate func deliver() {
            onChange?()
        }
    }

    let relay = Relay()
    private(set) var isListening = false

    isolated deinit {
        stop()
    }

    func start(_ onChange: @escaping @MainActor () -> Void) {
        relay.onChange = onChange
        guard !isListening else { return }
        isListening = true
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.callback, context)
        }
    }

    /// Changes already reported but not yet delivered are dropped too.
    func stop() {
        relay.onChange = nil
        guard isListening else { return }
        isListening = false
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.callback, context)
        }
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(relay).toOpaque() }

    /// Runs on a HAL thread; the handler runs a main-actor turn later, so it may remove this listener.
    static let callback: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let relay = Unmanaged<Relay>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { relay.deliver() }
        }
        return noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
