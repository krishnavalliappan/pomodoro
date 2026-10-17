import AppKit
import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class FloatingTimerModelTests: XCTestCase {
    func testShowsOnlyWhileASessionRuns() throws {
        let h = try ModelHarness(display: .iconOnly)
        h.updateSettings { $0.showsFloatingTimer = true }
        let model = h.makeModel()
        XCTAssertFalse(model.showsFloatingTimer)
        model.startFocus()
        XCTAssertTrue(model.showsFloatingTimer)
        model.pause()
        XCTAssertTrue(model.showsFloatingTimer, "paused still counts")
        model.stopAndLog()
        XCTAssertFalse(model.showsFloatingTimer)

        model.setShowsFloatingTimer(false)
        model.startFocus()
        XCTAssertFalse(model.showsFloatingTimer)
        XCTAssertFalse(h.settingsStore.load().showsFloatingTimer, "saved")
    }

    /// The card shows seconds, so it keeps the tick going even with an icon-only menu bar.
    func testTicksEverySecondWhileTheCardShows() throws {
        let h = try ModelHarness(display: .iconOnly)
        h.updateSettings { $0.showsFloatingTimer = true }
        let model = h.makeModel()
        model.startFocus()
        XCTAssertTrue(model.isRefreshingEverySecond)
        model.setShowsFloatingTimer(false)
        XCTAssertFalse(model.isRefreshingEverySecond)
    }

    func testMuteSilencesChimesUntilUnmuted() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.toggleMute()
        XCTAssertTrue(model.isMuted)
        XCTAssertTrue(h.settingsStore.load().isMuted, "saved")
        model.startFocus()
        XCTAssertEqual(h.plays(.start), 0)

        model.toggleMute()
        model.skip()
        XCTAssertEqual(h.plays(.start), 1, "heard again once unmuted")
    }

    /// A chime already sounding goes quiet too, and comes back at the set volume.
    func testMuteSilencesAChimeAlreadyPlaying() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        let start = try XCTUnwrap(h.players[.start])
        XCTAssertGreaterThan(start.volume, 0)
        model.toggleMute()
        XCTAssertEqual(start.volume, 0)
        model.toggleMute()
        XCTAssertEqual(start.volume, Float(model.settings.sounds.volume))
    }

    func testMuteStopsTheTick() throws {
        let h = try ModelHarness()
        h.updateSettings { $0.sounds.tick = .tick }
        let model = h.makeModel()
        model.startFocus()
        XCTAssertTrue(model.sound.isTicking)
        model.toggleMute()
        XCTAssertFalse(model.sound.isTicking)
        model.toggleMute()
        XCTAssertTrue(model.sound.isTicking, "focus still running: the tick comes back")
    }

    func testMuteFadesOutAmbientAndPreviews() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.toggleAmbient("rain")
        model.startFocus()
        // The harness has no update seam; this is the call it would make.
        model.ambient.update(phase: .focus, status: .running)
        XCTAssertTrue(model.isAmbientPlaying)
        model.toggleMute()
        XCTAssertFalse(model.isAmbientPlaying)
        model.previewAmbient("forest")
        XCTAssertFalse(model.isAmbientPlaying, "a preview stays silent too")
        model.toggleMute()
        XCTAssertTrue(model.isAmbientPlaying)
    }

    /// A launch with mute saved starts silent.
    func testMuteIsRestored() throws {
        let h = try ModelHarness()
        h.updateSettings { $0.isMuted = true }
        let model = h.makeModel()
        model.startFocus()
        XCTAssertEqual(h.plays(.start), 0)
    }

    func testCompletingTheCurrentTaskKeepsTheFocusOnIt() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        XCTAssertNil(model.openCurrentTask)
        let task = try XCTUnwrap(model.addTask("Write report"))
        model.startFocus(on: task.id)
        XCTAssertEqual(model.openCurrentTask?.id, task.id)

        model.completeCurrentTask()
        XCTAssertEqual(model.tasks.task(id: task.id)?.isDone, true)
        XCTAssertNil(model.openCurrentTask)
        XCTAssertEqual(model.selectedTaskID, task.id, "the session still counts toward it")
    }
}

@MainActor
final class FloatingTimerControllerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private var mouse = CGPoint.zero

    private func controller(_ model: AppModel, defaults: UserDefaults) -> FloatingTimerController {
        FloatingTimerController(
            model: model,
            defaults: defaults,
            screens: { [screen] in [screen] },
            mouseLocation: { [unowned self] in mouse },
            openPopover: {}
        )
    }

    func testFollowsTheSession() async throws {
        let h = try ModelHarness()
        h.updateSettings { $0.showsFloatingTimer = true }
        let model = h.makeModel()
        let floating = controller(model, defaults: PopoverViewSnapshotTests.freshDefaults())
        defer { floating.stop() }
        XCTAssertFalse(floating.isVisible)

        model.startFocus()
        await Task.yield()
        XCTAssertTrue(floating.isVisible)
        let size = FloatingTimerView.panelSize(collapsed: false)
        XCTAssertEqual(floating.panel?.frame, FloatingPlacement.defaultFrame(size: size, screens: [screen]))

        model.stopAndLog()
        await Task.yield()
        XCTAssertFalse(floating.isVisible)
    }

    func testDraggingMovesThenSettlesAndIsRemembered() async throws {
        let h = try ModelHarness()
        h.updateSettings { $0.showsFloatingTimer = true }
        let model = h.makeModel()
        let defaults = PopoverViewSnapshotTests.freshDefaults()
        let floating = controller(model, defaults: defaults)
        model.startFocus()
        await Task.yield()
        let start = try XCTUnwrap(floating.panel?.frame)

        mouse = CGPoint(x: 1000, y: 700)
        floating.drag(.began)
        mouse = CGPoint(x: 500, y: 400)
        floating.drag(.moved)
        XCTAssertEqual(floating.panel?.frame.origin, CGPoint(x: start.minX - 500, y: start.minY - 300))
        floating.drag(.ended)
        let dropped = try XCTUnwrap(floating.panel?.frame)
        XCTAssertEqual(dropped, FloatingPlacement.settled(dropped, screens: [screen]))
        floating.stop()

        let again = controller(model, defaults: defaults)
        defer { again.stop() }
        model.stopAndLog()
        model.startFocus()
        await Task.yield()
        XCTAssertEqual(again.panel?.frame.origin, dropped.origin, "comes back where it was left")
    }

    func testCollapsingKeepsItsCornerAndIsRemembered() async throws {
        let h = try ModelHarness()
        h.updateSettings { $0.showsFloatingTimer = true }
        let model = h.makeModel()
        let defaults = PopoverViewSnapshotTests.freshDefaults()
        let floating = controller(model, defaults: defaults)
        defer { floating.stop() }
        model.startFocus()
        await Task.yield()
        let docked = try XCTUnwrap(floating.panel?.frame)

        floating.setCollapsed(true)
        let small = try XCTUnwrap(floating.panel?.frame)
        XCTAssertEqual(small.size, FloatingTimerView.panelSize(collapsed: true))
        XCTAssertEqual(small.maxX, docked.maxX)
        XCTAssertEqual(small.maxY, docked.maxY)
        XCTAssertTrue(defaults.bool(forKey: FloatingTimerController.collapsedKey))

        let again = controller(model, defaults: defaults)
        defer { again.stop() }
        XCTAssertTrue(again.state.isCollapsed)
    }
}

@MainActor
final class FloatingTimerSnapshotTests: XCTestCase {
    func testFocusWithTaskAndHoverRow() throws {
        let h = try ModelHarness()
        try h.seedCompletedSessions(2)
        let model = h.makeModel()
        let task = try XCTUnwrap(model.addTask("Write quarterly report"))
        model.startFocus(on: task.id)
        h.clock.advance(by: 6 * 60 + 18)
        assertCard(model, "focus", isHovering: true)
    }

    func testBreak() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        model.skip()
        h.clock.advance(by: 2 * 60)
        assertCard(model, "break")
    }

    func testPausedAndMuted() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        h.clock.advance(by: 4 * 60)
        model.pause()
        model.toggleMute()
        assertCard(model, "paused")
    }

    /// Hovered, so the row shows +5: time can still be added once it has run out.
    func testTimesUp() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: 25 * 60 + 5)
        assertCard(model, "timesUp", isHovering: true)
    }

    func testCollapsed() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        h.clock.advance(by: 10 * 60)
        assertCard(model, "collapsed", collapsed: true)
    }

    private func assertCard(
        _ model: AppModel,
        _ variant: String,
        collapsed: Bool = false,
        isHovering: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        model.setPopoverVisible(true)
        let view = FloatingTimerView(model: model, isCollapsed: collapsed, actions: FloatingTimerActions(), isHovering: isHovering)
        Snapshot.assertLightAndDark(
            view,
            size: FloatingTimerView.panelSize(collapsed: collapsed),
            name: "FloatingTimer",
            variant: variant,
            file: file,
            line: line
        )
    }
}
