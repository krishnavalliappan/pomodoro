import AVFoundation
import Foundation
import PomodoroCore
import os

/// Moments in a session that can make a sound, one per `SoundSettings` field.
enum SoundEvent: CaseIterable, Sendable {
    case focusEnd, breakEnd, start, tick

    var setting: WritableKeyPath<SoundSettings, SoundID> {
        switch self {
        case .focusEnd: \.focusEnd
        case .breakEnd: \.breakEnd
        case .start: \.start
        case .tick: \.tick
        }
    }
}

@MainActor
protocol SoundPlayer: AnyObject {
    var volume: Float { get set }
    /// Restarts from the beginning. Returns `false` if playback could not start.
    @discardableResult func play() -> Bool
}

/// The tick's scheduling time source, injectable so tests can jump time without real sleeps.
@MainActor
protocol TickClock: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct SystemTickClock: TickClock {
    private let clock = ContinuousClock()
    var now: ContinuousClock.Instant { clock.now }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await clock.sleep(until: deadline, tolerance: .milliseconds(10))
    }
}

@MainActor
final class AVSoundPlayer: SoundPlayer {
    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "sound")

    private let player: AVAudioPlayer
    private let name: String

    init?(contentsOf url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        self.name = url.lastPathComponent
        // Primes the first play only; AVAudioPlayer undoes preparation once playback stops.
        if !player.prepareToPlay() {
            Self.log.error("prepareToPlay failed for \(self.name, privacy: .public)")
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play() -> Bool {
        if player.isPlaying {
            player.stop()
        }
        player.currentTime = 0
        let started = player.play()
        if !started {
            Self.log.error("play failed for \(self.name, privacy: .public)")
        }
        return started
    }
}

/// Cancels its task when released. A `@MainActor` deinit can't touch isolated state on
/// macOS 14, so dropping the service cancels the cadence by releasing this handle instead.
private final class CancelOnDeinit: Sendable {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}

@MainActor
final class SoundService {
    static let resourceSubdirectory = "Sounds"
    static let tickInterval: Duration = .seconds(1)
    /// A beat later than this (sleep, a main-actor stall) is dropped rather than played late.
    static let lateBeatTolerance: Duration = .milliseconds(250)

    private static let fileNames: [SoundID: String] = [
        .chimeFocusEnd: "chime_focus_end",
        .chimeBreakEnd: "chime_break_end",
        .start: "start",
        .tick: "tick",
        .bowl: "bowl",
    ]

    static func url(for sound: SoundID, in bundle: Bundle = .main) -> URL? {
        guard let name = fileNames[sound] else { return nil }
        return bundle.url(forResource: name, withExtension: "wav", subdirectory: resourceSubdirectory)
    }

    /// The tick sounds only between `startTicking()` and `stopTicking()`, and never while
    /// `settings.tick` is `.none` (the default).
    var settings: SoundSettings {
        didSet {
            if settings.volume != oldValue.volume { applyVolume() }
            if settings.tick == .none { stopTicking() }
        }
    }

    /// Nothing plays while set, the tick included.
    var isMuted = false {
        didSet { if isMuted { stopTicking() } }
    }

    private let players: [SoundID: any SoundPlayer]
    private let clock: any TickClock
    private var tickTask: CancelOnDeinit?

    init(
        settings: SoundSettings = SoundSettings(),
        players: [SoundID: any SoundPlayer],
        clock: any TickClock = SystemTickClock()
    ) {
        self.settings = settings
        self.players = players
        self.clock = clock
        applyVolume()
    }

    /// Loads every bundled sound up front so a chime doesn't wait on disk.
    convenience init(bundle: Bundle = .main, settings: SoundSettings = SoundSettings()) {
        var players: [SoundID: any SoundPlayer] = [:]
        for sound in SoundID.allCases {
            guard let url = Self.url(for: sound, in: bundle),
                let player = AVSoundPlayer(contentsOf: url)
            else { continue }
            players[sound] = player
        }
        self.init(settings: settings, players: players)
    }

    func isLoaded(_ sound: SoundID) -> Bool {
        players[sound] != nil
    }

    var isTicking: Bool { tickTask != nil }

    func play(for event: SoundEvent) {
        play(settings[keyPath: event.setting])
    }

    /// Plays a sound directly, e.g. to preview a choice in Settings.
    func play(_ sound: SoundID) {
        guard !isMuted, settings.volume > 0, let player = players[sound] else { return }
        player.play()
    }

    /// Call when focus starts or resumes; a no-op while the tick sound is `.none`.
    func startTicking() {
        guard !isMuted, settings.tick != .none, tickTask == nil else { return }
        // Weak so the cadence never keeps the service alive; releasing it cancels the task.
        tickTask = CancelOnDeinit(Task { [weak self, clock = self.clock] in
            await Self.runCadence(clock: clock) {
                guard let self else { return false }
                self.play(for: .tick)
                return true
            }
        })
    }

    /// Call when focus pauses or ends.
    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Beats on a whole-second grid from the first beat. Purely audible: the timer's phase comes
    /// from the wall clock, so dropped beats lose nothing.
    static func runCadence(clock: any TickClock, beat: () -> Bool) async {
        let anchor = clock.now
        var deadline = anchor
        while true {
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            if Task.isCancelled { return }
            let now = clock.now
            if now - deadline <= lateBeatTolerance {
                guard beat() else { return }
            }
            // After a system sleep the backlog is skipped, never replayed.
            deadline = nextBeat(after: max(now, deadline), anchor: anchor)
        }
    }

    /// The first grid beat strictly after `instant`.
    static func nextBeat(after instant: ContinuousClock.Instant, anchor: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let elapsedBeats = Int(((instant - anchor) / tickInterval).rounded(.down))
        return anchor + tickInterval * (elapsedBeats + 1)
    }

    private func applyVolume() {
        let volume = Float(settings.volume)
        for player in players.values { player.volume = volume }
    }
}
