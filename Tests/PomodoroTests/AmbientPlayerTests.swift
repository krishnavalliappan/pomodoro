import Foundation
import PomodoroCore
import XCTest
@testable import Pomodoro

/// Stands in for AVAudioEngine: voices are entries, and ramps wait until a test finishes them.
@MainActor
final class FakeAmbientEngine: AmbientAudioEngine {
    struct Ramp {
        let volume: Float
        let duration: TimeInterval
        let completion: @MainActor () -> Void
    }

    struct StartFailure: Error {}

    var onConfigurationChange: (@MainActor () -> Void)?
    var failsToStart = false
    private(set) var isRunning = false
    private(set) var isWaitingForOutput = false
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var volumes: [AmbientSound.ID: Float] = [:]
    private(set) var ramps: [AmbientSound.ID: Ramp] = [:]
    private(set) var added: [AmbientSound.ID] = []

    var voices: Set<AmbientSound.ID> { Set(volumes.keys) }

    func start() throws {
        if failsToStart {
            isWaitingForOutput = true
            throw StartFailure()
        }
        isWaitingForOutput = false
        isRunning = true
        starts += 1
    }

    func stop() {
        isRunning = false
        isWaitingForOutput = false
        stops += 1
        volumes = [:]
        ramps = [:]
    }

    func addVoice(_ sound: AmbientSound) throws {
        XCTAssertTrue(isRunning, "voice added to a stopped engine")
        volumes[sound.id] = 0
        added.append(sound.id)
    }

    func removeVoice(_ id: AmbientSound.ID) {
        volumes[id] = nil
        ramps[id] = nil
    }

    func ramp(_ id: AmbientSound.ID, to volume: Float, over duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard volumes[id] != nil else { return completion() }
        ramps[id] = Ramp(volume: volume, duration: duration, completion: completion)
    }

    /// Lands every ramp in flight, as if its duration passed.
    func finishRamps() {
        let due = ramps
        ramps = [:]
        for (id, ramp) in due.sorted(by: { $0.key < $1.key }) {
            volumes[id] = ramp.volume
            ramp.completion()
        }
    }

    /// The output device changed: the system stops the engine, losing its voices.
    func changeConfiguration() {
        isRunning = false
        volumes = [:]
        ramps = [:]
        onConfigurationChange?()
    }
}

extension AmbientLibrary {
    static func fixture(_ ids: [AmbientSound.ID] = ["cafe", "forest", "rain"]) -> AmbientLibrary {
        AmbientLibrary(sounds: ids.map { id in
            AmbientSound(
                id: id, title: id.capitalized, symbol: "circle", file: "\(id).m4a", frames: 441_000, duration: 10,
                source: AmbientSource(kind: .generated), credit: nil)
        })
    }
}

@MainActor
final class AmbientPlayerTests: XCTestCase {
    private let fade = AmbientPlayer.fadeDuration
    private var clock: TestClock!
    private var scheduler: FakeScheduler!
    private var engine: FakeAmbientEngine!
    private let overtime = TimerStatus.overtime(since: Date(timeIntervalSince1970: 0))

    override func setUp() async throws {
        clock = TestClock(now: ModelHarness.start)
        scheduler = FakeScheduler(clock: clock)
        engine = FakeAmbientEngine()
    }

    private func makePlayer(
        _ sounds: [AmbientSound.ID] = ["rain"], volume: Double = 0.5, breaks: AmbientBreakBehavior = .off
    ) -> AmbientPlayer {
        AmbientPlayer(
            library: .fixture(), engine: engine, scheduler: scheduler, clock: clock,
            mix: AmbientMix(sounds: sounds, volume: volume), policy: AmbientPolicy(duringBreaks: breaks))
    }

    private func focusing(_ player: AmbientPlayer) {
        player.update(phase: .focus, status: .running)
        engine.finishRamps()
    }

    // MARK: Following the timer

    func testSilentAndStoppedUntilFocus() {
        let player = makePlayer()
        player.update(phase: .idle, status: .awaitingDecision)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.starts, 0)

        player.update(phase: .focus, status: .running)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.voices, ["rain"])
        XCTAssertEqual(engine.ramps["rain"]?.volume, 0.5)
        XCTAssertEqual(engine.ramps["rain"]?.duration, fade, "fades in")
        engine.finishRamps()
        XCTAssertEqual(engine.volumes["rain"], 0.5)
        XCTAssertTrue(player.isAudible)
    }

    func testPauseFadesOutThenStopsTheEngine() {
        let player = makePlayer()
        focusing(player)

        player.update(phase: .focus, status: .paused)
        XCTAssertEqual(engine.ramps["rain"]?.volume, 0)
        XCTAssertEqual(engine.ramps["rain"]?.duration, fade)
        XCTAssertTrue(engine.isRunning, "still fading")

        engine.finishRamps()
        XCTAssertTrue(engine.voices.isEmpty)
        XCTAssertFalse(engine.isRunning, "nothing plays, so nothing runs")
        XCTAssertFalse(player.isAudible)
    }

    func testResumingMidFadeComesBackWithoutDroppingTheVoice() {
        let player = makePlayer()
        focusing(player)
        player.update(phase: .focus, status: .paused)
        player.update(phase: .focus, status: .running)
        XCTAssertEqual(engine.ramps["rain"]?.volume, 0.5, "the fade back up replaces the fade out")

        engine.finishRamps()
        XCTAssertEqual(engine.voices, ["rain"])
        XCTAssertEqual(engine.added, ["rain"], "the loop kept its place")
        XCTAssertTrue(engine.isRunning)
    }

    func testOvertimeKeepsPlaying() {
        let player = makePlayer()
        focusing(player)
        player.update(phase: .focus, status: overtime)
        XCTAssertTrue(engine.ramps.isEmpty)
        XCTAssertEqual(engine.volumes["rain"], 0.5)
    }

    func testFocusBreakFocusWithBreaksOff() {
        let player = makePlayer()
        focusing(player)

        player.update(phase: .shortBreak, status: .running)
        engine.finishRamps()
        XCTAssertFalse(engine.isRunning)

        player.update(phase: .focus, status: .running)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.ramps["rain"]?.duration, fade)
        engine.finishRamps()
        XCTAssertEqual(engine.volumes["rain"], 0.5)
        XCTAssertEqual(engine.starts, 2)
    }

    func testBreaksLowered() throws {
        let player = makePlayer(breaks: .lower)
        focusing(player)

        player.update(phase: .longBreak, status: .running)
        XCTAssertEqual(engine.ramps["rain"]?.duration, fade)
        engine.finishRamps()
        XCTAssertEqual(try XCTUnwrap(engine.volumes["rain"]), Float(0.5 * AmbientPolicy.loweredLevel), accuracy: 1e-6)

        player.update(phase: .focus, status: .running)
        XCTAssertEqual(engine.ramps["rain"]?.duration, fade)
        engine.finishRamps()
        XCTAssertEqual(engine.volumes["rain"], 0.5)
    }

    func testBreaksKept() {
        let player = makePlayer(breaks: .keep)
        focusing(player)
        player.update(phase: .shortBreak, status: .running)
        XCTAssertTrue(engine.ramps.isEmpty)
        XCTAssertEqual(engine.volumes["rain"], 0.5)

        player.update(phase: .shortBreak, status: .paused)
        engine.finishRamps()
        XCTAssertFalse(engine.isRunning, "a paused break is silent too")
    }

    func testStopFadesOut() {
        let player = makePlayer(breaks: .keep)
        focusing(player)
        player.update(phase: .idle, status: .awaitingDecision)
        engine.finishRamps()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.stops, 1)
    }

    // MARK: Changing the mix

    func testLayersFadeInAndOutOnTheirOwn() {
        let player = makePlayer(["rain"])
        focusing(player)

        player.configure(mix: AmbientMix(sounds: ["rain", "forest"], volume: 0.5), policy: player.policy)
        XCTAssertNil(engine.ramps["rain"], "the playing layer is left alone")
        XCTAssertEqual(engine.ramps["forest"]?.volume, 0.5)
        XCTAssertEqual(engine.ramps["forest"]?.duration, fade)
        engine.finishRamps()

        player.configure(mix: AmbientMix(sounds: ["forest"], volume: 0.5), policy: player.policy)
        XCTAssertEqual(engine.ramps["rain"]?.volume, 0)
        engine.finishRamps()
        XCTAssertEqual(engine.voices, ["forest"])
        XCTAssertTrue(engine.isRunning)

        player.configure(mix: AmbientMix(volume: 0.5), policy: player.policy)
        engine.finishRamps()
        XCTAssertFalse(engine.isRunning, "the last layer off stops the engine")
    }

    func testVolumeAndLevelChangesFollowQuickly() {
        let player = makePlayer(["rain", "cafe"])
        focusing(player)

        var mix = player.mix
        mix.volume = 0.8
        mix.setLevel(0.5, for: "cafe")
        player.configure(mix: mix, policy: player.policy)
        XCTAssertEqual(engine.ramps["rain"]?.volume, 0.8)
        XCTAssertEqual(engine.ramps["rain"]?.duration, AmbientPlayer.adjustDuration)
        XCTAssertEqual(engine.ramps["cafe"]?.volume, 0.4)
    }

    func testZeroVolumeNeverStartsTheEngine() {
        let player = makePlayer(volume: 0)
        player.update(phase: .focus, status: .running)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.starts, 0)
    }

    func testEmptyMixNeverStartsTheEngine() {
        let player = makePlayer([])
        player.update(phase: .focus, status: .running)
        XCTAssertEqual(engine.starts, 0)
    }

    func testSoundsMissingFromTheLibraryAreDropped() {
        let player = makePlayer(["gone", "rain"])
        XCTAssertEqual(player.mix.sounds, ["rain"])
        focusing(player)
        XCTAssertEqual(engine.voices, ["rain"])
    }

    // MARK: Preview

    func testPreviewPlaysWhileIdleThenFadesOut() {
        let player = makePlayer([], volume: 0.4)
        player.preview("forest")
        XCTAssertEqual(player.previewing, "forest")
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.ramps["forest"]?.volume, 0.4)
        engine.finishRamps()

        scheduler.advance(by: AmbientPlayer.previewDuration)
        XCTAssertNil(player.previewing)
        XCTAssertEqual(engine.ramps["forest"]?.volume, 0)
        engine.finishRamps()
        XCTAssertFalse(engine.isRunning)
    }

    func testPreviewingAPlayingSoundLeavesItPlaying() {
        let player = makePlayer(["rain"])
        focusing(player)
        player.preview("rain")
        XCTAssertTrue(engine.ramps.isEmpty)
        player.stopPreview()
        XCTAssertTrue(engine.ramps.isEmpty)
        XCTAssertEqual(engine.volumes["rain"], 0.5)
    }

    func testPreviewingAgainRestartsItsTime() {
        let player = makePlayer([])
        player.preview("rain")
        scheduler.advance(by: AmbientPlayer.previewDuration - 1)
        player.preview("rain")
        scheduler.advance(by: 2)
        XCTAssertEqual(player.previewing, "rain")
        scheduler.advance(by: AmbientPlayer.previewDuration)
        XCTAssertNil(player.previewing)
    }

    func testPreviewOfAnUnknownSoundDoesNothing() {
        let player = makePlayer([])
        player.preview("gone")
        XCTAssertNil(player.previewing)
        XCTAssertEqual(engine.starts, 0)
    }

    // MARK: Device changes and failures

    func testConfigurationChangeRestartsWhatWasPlaying() {
        let player = makePlayer(["rain", "cafe"])
        focusing(player)

        engine.changeConfiguration()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.voices, ["rain", "cafe"])
        XCTAssertEqual(engine.ramps["rain"]?.duration, fade, "fades back in on the new device")
        XCTAssertEqual(engine.starts, 2)
    }

    func testConfigurationChangeWhileSilentStaysStopped() {
        let player = makePlayer()
        player.update(phase: .idle, status: .awaitingDecision)
        engine.changeConfiguration()
        XCTAssertEqual(engine.starts, 0)
    }

    func testStartFailureStaysSilentAndRetriesOnTheNextChange() {
        engine.failsToStart = true
        let player = makePlayer()
        player.update(phase: .focus, status: .running)
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(player.isAudible)

        engine.failsToStart = false
        engine.changeConfiguration()
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.voices, ["rain"])
    }

    func testShutdownStopsEverything() {
        let player = makePlayer()
        focusing(player)
        player.shutdown()
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(engine.voices.isEmpty)
    }
}

/// The model's ambient API and the update seam, end to end with a fake engine.
@MainActor
final class AppModelAmbientTests: XCTestCase {
    func testToggleSavesAndPlaysOnlyDuringFocus() throws {
        let h = try ModelHarness()
        let services = AppServices(
            notifications: NotificationService(center: FakeNotificationCenter(clock: h.clock), clock: h.clock, pause: { await Task.yield() }),
            appNap: AppNapGuard(scheduler: FakeActivityScheduler()),
            ambient: h.makeAmbientPlayer(),
            makeModel: { h.makeModel(ambient: $0, onEngineUpdate: $1) },
            makeSystemEvents: { SystemEvents(workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter(), localCenter: NotificationCenter(), reconcile: $0) }
        )
        let m = services.model
        m.toggleAmbient("rain")
        XCTAssertEqual(m.ambientMix.sounds, ["rain"])
        XCTAssertEqual(h.settingsStore.load().ambient.sounds, ["rain"], "saved")
        XCTAssertFalse(h.ambientEngine.isRunning, "idle stays silent")

        m.startFocus()
        XCTAssertEqual(h.ambientEngine.voices, ["rain"])
        h.ambientEngine.finishRamps()
        XCTAssertEqual(h.ambientEngine.volumes["rain"], Float(AmbientMix.defaultVolume))

        m.setAmbientVolume(0.2)
        XCTAssertEqual(h.ambientEngine.ramps["rain"]?.volume, 0.2)
        h.ambientEngine.finishRamps()

        m.pause()
        h.ambientEngine.finishRamps()
        XCTAssertFalse(h.ambientEngine.isRunning)

        m.resume()
        XCTAssertTrue(h.ambientEngine.isRunning)
        m.stopAndLog()
        h.ambientEngine.finishRamps()
        XCTAssertFalse(h.ambientEngine.isRunning)
    }

    func testBreakBehaviorIsSavedAndApplied() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.setAmbientBreakBehavior(.keep)
        XCTAssertEqual(model.ambientPolicy.duringBreaks, .keep)
        XCTAssertEqual(h.settingsStore.load().ambientPolicy.duringBreaks, .keep)
        XCTAssertEqual(model.ambient.policy.duringBreaks, .keep)
    }

    func testRestoredFocusResumesItsSoundsAtLaunch() throws {
        let h = try ModelHarness()
        let first = h.makeModel()
        first.toggleAmbient("forest")
        first.startFocus()
        first.shutdown()

        let engine = FakeAmbientEngine()
        let player = AmbientPlayer(library: .bundled(), engine: engine, scheduler: h.scheduler, clock: h.clock)
        _ = AppServices(
            notifications: NotificationService(center: FakeNotificationCenter(clock: h.clock), clock: h.clock, pause: { await Task.yield() }),
            appNap: AppNapGuard(scheduler: FakeActivityScheduler()),
            ambient: player,
            makeModel: { h.makeModel(ambient: $0, onEngineUpdate: $1) },
            makeSystemEvents: { SystemEvents(workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter(), localCenter: NotificationCenter(), reconcile: $0) }
        )
        XCTAssertEqual(engine.voices, ["forest"], "the launch reconcile reaches the player")
    }

    func testAvailableSoundsAndUnknownIDs() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        XCTAssertEqual(model.availableAmbientSounds.count, 15)
        XCTAssertEqual(model.availableAmbientSounds.first?.title, "Forest")
        XCTAssertEqual(model.availableAmbientSounds.first?.symbol, "tree")
        XCTAssertNotNil(model.availableAmbientSounds.first { $0.id == "rain" }?.credit)

        model.toggleAmbient("not-a-sound")
        XCTAssertTrue(model.ambientMix.isEmpty)
        model.setAmbientLevel(0.3, for: "rain")
        XCTAssertEqual(model.ambientMix.level(for: "rain"), 0.3)
    }

    func testPreviewPlaysWithTheTimerIdle() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.previewAmbient("waves")
        XCTAssertEqual(model.previewingAmbient, "waves")
        XCTAssertEqual(h.ambientEngine.voices, ["waves"])
        model.stopAmbientPreview()
        h.ambientEngine.finishRamps()
        XCTAssertFalse(h.ambientEngine.isRunning)
    }

    // MARK: Sounds tab

    func testTappingWhileIdleSavesAndPreviews() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.tapAmbient("rain")
        XCTAssertEqual(h.settingsStore.load().ambient.sounds, ["rain"], "saved")
        XCTAssertEqual(model.previewingAmbient, "rain", "heard at once")
        XCTAssertTrue(model.isAmbientPlaying)

        model.tapAmbient("forest")
        XCTAssertEqual(model.previewingAmbient, "forest", "the newest tap is the one previewed")

        model.tapAmbient("forest")
        XCTAssertEqual(model.ambientMix.sounds, ["rain"])
        XCTAssertNil(model.previewingAmbient, "switching off stops its own preview")
        XCTAssertFalse(model.isAmbientPlaying, "idle: the mix waits for focus")
    }

    func testTappingDuringFocusPlaysWithoutAPreview() throws {
        let h = try ModelHarness()
        let model = services(h).model
        model.startFocus()
        model.tapAmbient("rain")
        XCTAssertNil(model.previewingAmbient)
        XCTAssertEqual(h.ambientEngine.voices, ["rain"])
        XCTAssertTrue(model.isAmbientPlaying)
    }

    /// A preview started while idle would otherwise outlast its tile being switched off in focus.
    func testSwitchingOffDuringFocusStopsAPreviewFromBefore() throws {
        let h = try ModelHarness()
        let model = services(h).model
        model.tapAmbient("rain")
        XCTAssertEqual(model.previewingAmbient, "rain")
        model.startFocus()
        model.tapAmbient("rain")
        XCTAssertNil(model.previewingAmbient)
        XCTAssertTrue(model.ambientMix.isEmpty)
        h.ambientEngine.finishRamps()
        XCTAssertTrue(h.ambientEngine.voices.isEmpty)
    }

    /// A slider reports every step of a drag: each one is heard, only the last is saved, and
    /// none reschedules the timer.
    func testVolumeFollowsEveryStepAndSavesOnceItSettles() throws {
        let h = try ModelHarness()
        let model = services(h).model
        model.toggleAmbient("rain")
        model.startFocus()
        h.ambientEngine.finishRamps()
        let scheduled = h.scheduler.scheduledCount
        for volume in [0.5, 0.4, 0.3, 0.2] {
            model.setAmbientVolume(volume)
        }
        XCTAssertEqual(h.ambientEngine.ramps["rain"]?.volume ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(model.ambientMix.volume, 0.2, accuracy: 0.0001)
        XCTAssertEqual(h.scheduler.scheduledCount - scheduled, 4, "one pending save per step, nothing else")
        XCTAssertEqual(h.settingsStore.load().ambient.volume, AmbientMix.defaultVolume, "not saved mid-drag")

        h.scheduler.advance(by: AppModel.settingsSaveDelay)
        XCTAssertEqual(h.settingsStore.load().ambient.volume, 0.2, accuracy: 0.0001)
    }

    /// Another setting saved mid-drag takes the volume with it, and the pending save, now moot, never fires.
    func testASettingSavedWhileTheVolumeSettlesKeepsBoth() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.setAmbientVolume(0.3)
        model.updateSettings { $0.menuBarDisplay = .iconOnly }
        XCTAssertEqual(h.settingsStore.load().ambient.volume, 0.3)
        let fired = h.scheduler.firedCount
        h.scheduler.advance(by: AppModel.settingsSaveDelay)
        XCTAssertEqual(h.scheduler.firedCount, fired, "the pending save was cancelled")
        XCTAssertEqual(h.settingsStore.load().menuBarDisplay, .iconOnly)
        XCTAssertEqual(h.settingsStore.load().ambient.volume, 0.3)
    }

    func testAVolumeStillSettlingIsSavedAtQuit() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.setAmbientVolume(0.3)
        model.shutdown()
        XCTAssertEqual(h.settingsStore.load().ambient.volume, 0.3)
    }

    func testStopAllKeepsLevels() throws {
        let h = try ModelHarness()
        let model = services(h).model
        model.setAmbientLevel(0.5, for: "rain")
        model.toggleAmbient("rain")
        model.toggleAmbient("waves")
        model.startFocus()
        XCTAssertTrue(model.isAmbientPlaying)

        model.stopAllAmbient()
        h.ambientEngine.finishRamps()
        XCTAssertTrue(h.settingsStore.load().ambient.isEmpty, "saved")
        XCTAssertEqual(model.ambientMix.level(for: "rain"), 0.5)
        XCTAssertFalse(model.isAmbientPlaying)
        XCTAssertFalse(h.ambientEngine.isRunning)
    }

    func testCaption() {
        let sounds = AmbientLibrary.bundled(in: Bundle(for: AppModel.self)).sounds
        XCTAssertEqual(PopoverSoundsTab.caption(mix: AmbientMix(), sounds: sounds, isPlaying: false), "Tap sounds to mix them. They play during focus.")
        let mix = AmbientMix(sounds: ["rain", "forest"])
        XCTAssertEqual(PopoverSoundsTab.caption(mix: mix, sounds: sounds, isPlaying: false), "Rain + Forest · plays during focus")
        XCTAssertEqual(PopoverSoundsTab.caption(mix: mix, sounds: sounds, isPlaying: true), "Rain + Forest · playing")
    }

    /// The model with the update seam wired, as at launch, so the timer drives the player.
    private func services(_ h: ModelHarness) -> AppServices {
        AppServices(
            notifications: NotificationService(center: FakeNotificationCenter(clock: h.clock), clock: h.clock, pause: { await Task.yield() }),
            appNap: AppNapGuard(scheduler: FakeActivityScheduler()),
            ambient: h.makeAmbientPlayer(),
            makeModel: { h.makeModel(ambient: $0, onEngineUpdate: $1) },
            makeSystemEvents: { SystemEvents(workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter(), localCenter: NotificationCenter(), reconcile: $0) }
        )
    }
}
