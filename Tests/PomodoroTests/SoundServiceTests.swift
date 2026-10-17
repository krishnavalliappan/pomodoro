import AVFoundation
import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
private final class FakePlayer: SoundPlayer {
    var volume: Float = 1
    private(set) var plays = 0
    func play() -> Bool {
        plays += 1
        return true
    }
}

/// Each sleep returns at its deadline plus the next scripted lateness, so tests can model a
/// system sleep or a main-actor stall without waiting.
@MainActor
private final class FakeTickClock: TickClock {
    private(set) var now = ContinuousClock.now
    private(set) var deadlines: [ContinuousClock.Instant] = []
    private var lateness: [Duration]
    private let maxSleeps: Int

    init(lateness: [Duration] = [], maxSleeps: Int = 10_000) {
        self.lateness = lateness
        self.maxSleeps = maxSleeps
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        if deadlines.count >= maxSleeps { throw CancellationError() }
        deadlines.append(deadline)
        await Task.yield()
        try Task.checkCancellation()
        now = max(now, deadline) + (lateness.isEmpty ? .zero : lateness.removeFirst())
    }
}

@MainActor
final class SoundServiceTests: XCTestCase {
    private var appBundle: Bundle { Bundle(for: SoundService.self) }

    private func fakePlayers() -> [SoundID: FakePlayer] {
        Dictionary(uniqueKeysWithValues: SoundID.allCases.filter { $0 != .none }.map { ($0, FakePlayer()) })
    }

    private func yield(until condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
    }

    // MARK: Resources

    func testEverySoundResourceExistsAndLoads() throws {
        for sound in SoundID.allCases where sound != .none {
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
        for sound in SoundID.allCases where sound != .none {
            XCTAssertTrue(service.isLoaded(sound), "\(sound) not preloaded")
        }
        XCTAssertFalse(service.isLoaded(.none))
    }

    func testTickDurationIsShort() throws {
        let url = try XCTUnwrap(SoundService.url(for: .tick, in: appBundle))
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertLessThan(player.duration, 0.1)
    }

    // MARK: Settings

    func testEventsMapOneToOneOntoSoundSettings() {
        let settings = SoundSettings(focusEnd: .bowl, breakEnd: .start, start: .tick, tick: .chimeFocusEnd)
        XCTAssertEqual(settings[keyPath: SoundEvent.focusEnd.setting], .bowl)
        XCTAssertEqual(settings[keyPath: SoundEvent.breakEnd.setting], .start)
        XCTAssertEqual(settings[keyPath: SoundEvent.start.setting], .tick)
        XCTAssertEqual(settings[keyPath: SoundEvent.tick.setting], .chimeFocusEnd)
    }

    func testPlayForEventUsesTheChosenSound() {
        let players = fakePlayers()
        let service = SoundService(settings: SoundSettings(focusEnd: .bowl), players: players)
        service.play(for: .focusEnd)
        XCTAssertEqual(players[.bowl]?.plays, 1)
        XCTAssertEqual(players[.chimeFocusEnd]?.plays, 0)
    }

    func testChoosingNoneIsSilent() {
        let players = fakePlayers()
        let service = SoundService(settings: SoundSettings(focusEnd: .none), players: players)
        service.play(for: .focusEnd)
        service.play(.none)
        XCTAssertEqual(players.values.map(\.plays).reduce(0, +), 0)
    }

    func testZeroVolumeIsSilent() {
        let players = fakePlayers()
        let service = SoundService(settings: SoundSettings(volume: 0), players: players)
        service.play(for: .focusEnd)
        XCTAssertEqual(players.values.map(\.plays).reduce(0, +), 0)
    }

    func testVolumeReachesEveryPlayer() {
        let players = fakePlayers()
        let service = SoundService(settings: SoundSettings(volume: 0.5), players: players)
        XCTAssertTrue(players.values.allSatisfy { $0.volume == 0.5 })
        service.settings.volume = 0.25
        XCTAssertTrue(players.values.allSatisfy { $0.volume == 0.25 })
    }

    // MARK: Tick

    func testTickIsOffByDefault() {
        let service = SoundService(players: fakePlayers(), clock: FakeTickClock())
        XCTAssertEqual(service.settings.tick, .none)
        service.startTicking()
        XCTAssertFalse(service.isTicking)
    }

    func testTickPlaysTheSelectedSoundAndStopsCleanly() async {
        let players = fakePlayers()
        let service = SoundService(settings: SoundSettings(tick: .bowl), players: players, clock: FakeTickClock())
        service.startTicking()
        XCTAssertTrue(service.isTicking)
        await yield { (players[.bowl]?.plays ?? 0) >= 3 }
        XCTAssertGreaterThanOrEqual(players[.bowl]?.plays ?? 0, 3)
        XCTAssertEqual(players[.tick]?.plays, 0)

        service.stopTicking()
        XCTAssertFalse(service.isTicking)
        let beats = players[.bowl]?.plays
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(players[.bowl]?.plays, beats, "beat after stopTicking()")
    }

    func testChoosingNoneTickStopsTicking() {
        let service = SoundService(settings: SoundSettings(tick: .tick), players: fakePlayers(), clock: FakeTickClock())
        service.startTicking()
        XCTAssertTrue(service.isTicking)
        service.settings.tick = .none
        XCTAssertFalse(service.isTicking)
    }

    func testCadenceSkipsBeatsMissedDuringSleep() async {
        // The third sleep overshoots by five minutes, as after the Mac wakes.
        let clock = FakeTickClock(lateness: [.zero, .zero, .seconds(300) + .milliseconds(400)], maxSleeps: 5)
        let anchor = clock.now
        var beats: [Duration] = []
        await SoundService.runCadence(clock: clock) {
            beats.append(clock.now - anchor)
            return true
        }
        XCTAssertEqual(beats, [.zero, .seconds(1), .seconds(303), .seconds(304)])
        XCTAssertEqual(clock.deadlines.map { $0 - anchor }, [.zero, .seconds(1), .seconds(2), .seconds(303), .seconds(304)])
    }

    func testCadenceKeepsSlightlyLateBeatsOnTheGrid() async {
        let clock = FakeTickClock(lateness: [.zero, .milliseconds(100)], maxSleeps: 3)
        let anchor = clock.now
        var beats: [Duration] = []
        await SoundService.runCadence(clock: clock) {
            beats.append(clock.now - anchor)
            return true
        }
        XCTAssertEqual(beats, [.zero, .milliseconds(1_100), .seconds(2)])
    }

    func testNextBeatIsAlwaysInTheFuture() {
        let anchor = ContinuousClock.now
        XCTAssertEqual(SoundService.nextBeat(after: anchor, anchor: anchor) - anchor, .seconds(1))
        XCTAssertEqual(SoundService.nextBeat(after: anchor + .milliseconds(999), anchor: anchor) - anchor, .seconds(1))
        XCTAssertEqual(SoundService.nextBeat(after: anchor + .seconds(600), anchor: anchor) - anchor, .seconds(601))
    }
}
