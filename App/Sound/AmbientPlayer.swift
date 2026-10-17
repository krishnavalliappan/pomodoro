import Foundation
import Observation
import PomodoroCore
import os

/// Plays the ambient mix while the timer says so, fading every change.
///
/// What should sound is a pure function of the mix, the policy, the timer and any preview;
/// `sync` moves the engine's voices toward it. Voices fade out before they're dropped, and once
/// the last one has gone the engine stops, so silence costs no CPU.
@MainActor
@Observable
final class AmbientPlayer {
    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "ambient")

    static let fadeDuration: TimeInterval = 1.5
    /// For volume sliders: quick enough to track the knob, slow enough not to click.
    static let adjustDuration: TimeInterval = 0.15
    static let previewDuration: TimeInterval = 6

    let library: AmbientLibrary
    private(set) var mix: AmbientMix
    private(set) var policy: AmbientPolicy
    /// The policy's level for the timer's state, 0…1.
    private(set) var timerLevel: Double = 0
    private(set) var previewing: AmbientSound.ID?
    /// Fades everything out, previews too, until unmuted.
    private(set) var isMuted = false

    @ObservationIgnored private let engine: any AmbientAudioEngine
    @ObservationIgnored private let scheduler: any TimerScheduling
    @ObservationIgnored private let clock: any TimeSource
    @ObservationIgnored private var previewTimer: (any ScheduledTimer)?
    /// Each voice's target volume; 0 while it fades out on its way to being dropped.
    @ObservationIgnored private var targets: [AmbientSound.ID: Float] = [:]

    init(
        library: AmbientLibrary,
        engine: any AmbientAudioEngine,
        scheduler: any TimerScheduling,
        clock: any TimeSource,
        mix: AmbientMix = AmbientMix(),
        policy: AmbientPolicy = AmbientPolicy()
    ) {
        self.library = library
        self.engine = engine
        self.scheduler = scheduler
        self.clock = clock
        self.mix = mix.restricted(to: library.ids)
        self.policy = policy
        engine.onConfigurationChange = { [weak self] in self?.configurationChanged() }
    }

    static func live() -> AmbientPlayer {
        AmbientPlayer(library: .bundled(), engine: AVAmbientEngine(), scheduler: RunLoopScheduler(), clock: SystemClock())
    }

    /// Sounds with a voice, including ones still fading out.
    var activeVoices: Set<AmbientSound.ID> { Set(targets.keys) }

    var isAudible: Bool { targets.values.contains { $0 > 0 } }

    /// Whether anything should be heard now. Unlike `isAudible`, built from observed state only,
    /// so views can follow it.
    var isPlaying: Bool { !desiredVolumes().isEmpty }

    /// Whether the timer has the mix playing; when it doesn't, a sound switched on is only heard
    /// as a preview.
    var timerPlaysMix: Bool { timerLevel > 0 }

    // MARK: - Inputs

    func update(with engine: TimerEngine) {
        update(phase: engine.phase, status: engine.status)
    }

    func update(phase: TimerPhase, status: TimerStatus) {
        let level = policy.level(phase: phase, status: status)
        guard level != timerLevel else { return }
        timerLevel = level
        sync(over: Self.fadeDuration)
    }

    func configure(mix: AmbientMix, policy: AmbientPolicy) {
        let mix = mix.restricted(to: library.ids)
        guard mix != self.mix || policy != self.policy else { return }
        // Only a level moved, e.g. a slider: follow it closely rather than fading.
        let adjusting = mix.sounds == self.mix.sounds && policy == self.policy
        self.mix = mix
        self.policy = policy
        sync(over: adjusting ? Self.adjustDuration : Self.fadeDuration)
    }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        sync(over: Self.fadeDuration)
    }

    /// Plays one sound for a few seconds whatever the timer is doing, at its level in the mix.
    func preview(_ id: AmbientSound.ID) {
        guard library.sound(id: id) != nil else { return }
        previewTimer?.cancel()
        previewTimer = scheduler.schedule(at: clock.now + Self.previewDuration) { [weak self] in
            self?.previewTimer = nil
            self?.stopPreview()
        }
        guard previewing != id else { return }
        previewing = id
        sync(over: Self.fadeDuration)
    }

    func stopPreview() {
        previewTimer?.cancel()
        previewTimer = nil
        guard previewing != nil else { return }
        previewing = nil
        sync(over: Self.fadeDuration)
    }

    /// Silences everything at once, e.g. at quit.
    func shutdown() {
        previewTimer?.cancel()
        previewTimer = nil
        targets = [:]
        engine.stop()
    }

    // MARK: - Syncing

    /// What each sound should play at now. Sounds at 0 are left out.
    func desiredVolumes() -> [AmbientSound.ID: Float] {
        guard !isMuted else { return [:] }
        var volumes: [AmbientSound.ID: Float] = [:]
        for id in mix.sounds {
            let volume = mix.volume * mix.level(for: id) * timerLevel
            if volume > 0 { volumes[id] = Float(volume) }
        }
        if let previewing {
            let volume = Float(mix.volume * mix.level(for: previewing))
            if volume > 0 { volumes[previewing] = max(volumes[previewing] ?? 0, volume) }
        }
        return volumes
    }

    private func sync(over duration: TimeInterval) {
        let desired = desiredVolumes()
        if !desired.isEmpty, !engine.isRunning {
            do {
                try engine.start()
            } catch {
                // No output device, say. The engine calls back once one appears.
                Self.log.error("starting ambient audio failed: \(String(describing: error), privacy: .public)")
                return
            }
        }
        for (id, volume) in desired.sorted(by: { $0.key < $1.key }) {
            let current = targets[id]
            if current == nil {
                guard let sound = library.sound(id: id) else { continue }
                do {
                    try engine.addVoice(sound)
                } catch {
                    Self.log.error("loading ambient sound \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    continue
                }
            }
            guard current != volume else { continue }
            targets[id] = volume
            // Coming in, or back from fading out, is always a fade.
            let fades = current == nil || current == 0
            engine.ramp(id, to: volume, over: fades ? Self.fadeDuration : duration) {}
        }
        for (id, target) in targets where desired[id] == nil && target > 0 {
            targets[id] = 0
            engine.ramp(id, to: 0, over: Self.fadeDuration) { [weak self] in self?.fadedOut(id) }
        }
        stopIfSilent()
    }

    private func fadedOut(_ id: AmbientSound.ID) {
        // A ramp back up replaces this one, so a voice reaching here is still meant to go.
        guard targets[id] == 0 else { return }
        targets[id] = nil
        engine.removeVoice(id)
        stopIfSilent()
    }

    private func stopIfSilent() {
        if targets.isEmpty, engine.isRunning || engine.isWaitingForOutput { engine.stop() }
    }

    /// The engine dropped its voices; bring back whatever should be playing.
    private func configurationChanged() {
        targets = [:]
        sync(over: Self.fadeDuration)
    }
}

extension AmbientLibrary {
    /// The library bundled with the app, or an empty one if its manifest can't be read.
    static func bundled(in bundle: Bundle = .main) -> AmbientLibrary {
        guard let url = bundle.url(forResource: manifestName, withExtension: "json", subdirectory: resourceSubdirectory) else {
            Logger(subsystem: "dev.krishna.pomodoro", category: "ambient").error("ambient manifest is missing from the bundle")
            return .empty
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            Logger(subsystem: "dev.krishna.pomodoro", category: "ambient")
                .error("reading the ambient manifest failed: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }
}
