import AVFoundation
import Foundation

// TODO(#4): Replace with PomodoroCore's `SoundID` once #4 merges; the cases match one-to-one.
enum AppSound: String, CaseIterable, Sendable {
    case chimeFocusEnd, chimeBreakEnd, start, tick, bowl, none
}

/// Moments in a session that can make a sound. Each one maps to a user-chosen `AppSound`.
enum SoundEvent: CaseIterable, Sendable {
    case focusEnd, breakEnd, start
}

@MainActor
final class SoundService {
    static let resourceSubdirectory = "Sounds"

    static let defaultChoices: [SoundEvent: AppSound] = [
        .focusEnd: .chimeFocusEnd,
        .breakEnd: .chimeBreakEnd,
        .start: .start,
    ]

    private static let fileNames: [AppSound: String] = [
        .chimeFocusEnd: "chime_focus_end",
        .chimeBreakEnd: "chime_break_end",
        .start: "start",
        .tick: "tick",
        .bowl: "bowl",
    ]

    static func url(for sound: AppSound, in bundle: Bundle = .main) -> URL? {
        guard let name = fileNames[sound] else { return nil }
        return bundle.url(forResource: name, withExtension: "wav", subdirectory: resourceSubdirectory)
    }

    var masterVolume: Float {
        didSet {
            masterVolume = min(max(masterVolume, 0), 1)
            for player in players.values { player.volume = masterVolume }
        }
    }

    var choices: [SoundEvent: AppSound]

    /// Off by default; even when on, it only sounds between `startTicking()` and `stopTicking()`.
    var tickEnabled: Bool {
        didSet { if !tickEnabled { stopTicking() } }
    }

    private var players: [AppSound: AVAudioPlayer] = [:]
    private var tickTask: Task<Void, Never>?

    init(
        bundle: Bundle = .main,
        masterVolume: Float = 0.8,
        choices: [SoundEvent: AppSound] = SoundService.defaultChoices,
        tickEnabled: Bool = false
    ) {
        self.masterVolume = min(max(masterVolume, 0), 1)
        self.choices = choices
        self.tickEnabled = tickEnabled
        // Decoding and priming up front means a chime never waits on disk or the audio graph.
        for sound in AppSound.allCases {
            guard let url = Self.url(for: sound, in: bundle),
                let player = try? AVAudioPlayer(contentsOf: url)
            else { continue }
            player.volume = self.masterVolume
            player.prepareToPlay()
            players[sound] = player
        }
    }

    func isLoaded(_ sound: AppSound) -> Bool {
        players[sound] != nil
    }

    var isTicking: Bool { tickTask != nil }

    func play(for event: SoundEvent) {
        play(choices[event] ?? .none)
    }

    /// Plays a sound directly, e.g. to preview a choice in Settings.
    func play(_ sound: AppSound) {
        guard masterVolume > 0, let player = players[sound] else { return }
        if player.isPlaying {
            player.stop()
        }
        player.currentTime = 0
        player.play()
    }

    /// Call when focus starts or resumes; a no-op unless the tick is enabled.
    func startTicking() {
        guard tickEnabled, tickTask == nil else { return }
        tickTask = Task { [weak self] in
            // Sleep to absolute deadlines so the tick doesn't drift with scheduling jitter.
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                // Checked each beat so the loop ends if the service is released without stopping.
                guard self?.play(.tick) != nil else { return }
                next += .seconds(1)
                do {
                    try await clock.sleep(until: next, tolerance: .milliseconds(10))
                } catch {
                    return
                }
            }
        }
    }

    /// Call when focus pauses or ends.
    func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
