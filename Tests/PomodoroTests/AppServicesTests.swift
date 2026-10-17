import AppKit
import PomodoroCore
import UserNotifications
import XCTest
@testable import Pomodoro

/// The model wired to the notification service, the App Nap guard and system events, with the
/// system notification center, timers and the clock all faked.
@MainActor
final class AppServicesTests: XCTestCase {
    private let focus: TimeInterval = 25 * 60
    private let start = ModelHarness.start
    private var h: ModelHarness!
    private var center: FakeNotificationCenter!
    private var activities: FakeActivityScheduler!
    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()
    private let local = NotificationCenter()

    override func setUp() async throws {
        h = try ModelHarness(display: .iconOnly)
        center = FakeNotificationCenter(clock: h.clock)
        activities = FakeActivityScheduler()
    }

    override func tearDown() async throws {
        XCTAssertLessThanOrEqual(center.mostOnScreen, 1, "two notifications were on screen at once")
    }

    private func makeNotifications() -> NotificationService {
        NotificationService(center: center, clock: h.clock, pause: { await Task.yield() })
    }

    private func makeServices(notifications: NotificationService? = nil) -> AppServices {
        let h: ModelHarness = self.h
        let (workspace, distributed, local) = (self.workspace, self.distributed, self.local)
        return AppServices(
            notifications: notifications ?? makeNotifications(),
            appNap: AppNapGuard(scheduler: activities),
            makeModel: { h.makeModel(onEngineUpdate: $0) },
            makeSystemEvents: {
                SystemEvents(workspaceCenter: workspace, distributedCenter: distributed, localCenter: local, reconcile: $0)
            }
        )
    }

    /// Lets the system deliver what is due at the focus end, then fires the model's boundary timer.
    private func reachFocusEnd(_ services: AppServices) async {
        h.clock.now = start + focus
        center.deliverDue()
        h.scheduler.advance(by: 0)
        await services.notifications.settle()
    }

    private var focusEndBanners: Int {
        center.banners.filter { $0.content.categoryIdentifier == NotificationService.Category.focusEnd }.count
    }

    // MARK: Prompts

    func testFocusReachingItsEndPromptsExactlyOnce() async throws {
        let services = makeServices()
        services.model.startFocus()
        await services.notifications.settle()
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, start + focus, "pre-scheduled at the boundary")
        XCTAssertTrue(services.appNap.isHolding)

        await reachFocusEnd(services)
        XCTAssertEqual(services.model.prompt, .focusEnded)
        XCTAssertEqual(focusEndBanners, 1)
        XCTAssertEqual(center.banners.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(center.onlyPending).fireDate, start + focus + TimerProfile.defaultNudgeInterval,
            "the next nudge replaces it later"
        )
    }

    func testPauseCancelsAndResumeReschedules() async throws {
        let services = makeServices()
        services.model.startFocus()
        h.scheduler.advance(by: 60)
        services.model.pause()
        await services.notifications.settle()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertFalse(services.appNap.isHolding, "nothing to wait for while paused")

        h.scheduler.advance(by: 120)
        services.model.resume()
        await services.notifications.settle()
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, start + focus + 120)
        XCTAssertTrue(services.appNap.isHolding)
    }

    // MARK: Actions

    private func respondAtFocusEnd(_ action: NotificationService.Action) async throws -> AppServices {
        let services = makeServices()
        services.model.startFocus()
        await reachFocusEnd(services)
        let banner = try XCTUnwrap(center.onlyDelivered)
        await center.respond(action, to: banner)
        await services.notifications.settle()
        return services
    }

    func testStartBreakActionStartsTheBreak() async throws {
        let services = try await respondAtFocusEnd(.startBreak)
        XCTAssertEqual(services.model.snapshot.phase, .shortBreak)
        XCTAssertEqual(services.model.completedToday, 1)
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, start + focus + 5 * 60)
    }

    func testExtendActionAddsFiveMinutes() async throws {
        let services = try await respondAtFocusEnd(.extendFocus)
        XCTAssertEqual(services.model.snapshot.phase, .focus)
        XCTAssertEqual(services.model.snapshot.status, .running)
        XCTAssertNil(services.model.prompt)
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, start + focus + 5 * 60)
    }

    func testKeepGoingActionSilencesNudges() async throws {
        let services = try await respondAtFocusEnd(.keepGoing)
        XCTAssertEqual(services.model.snapshot.status, .overtime(since: start + focus))
        XCTAssertNil(services.model.prompt)
        XCTAssertTrue(center.pending.isEmpty, "no nudge is scheduled")
        XCTAssertFalse(services.appNap.isHolding)
    }

    // MARK: Launch

    func testLaunchReconcileOfAnOverdueFocusSyncs() async throws {
        var services: AppServices? = makeServices()
        services?.model.startFocus()
        await services?.notifications.settle()
        services?.model.shutdown()
        services = nil
        // The system announces the end while the app isn't running.
        h.clock.advance(by: focus + 180)
        center.deliverDue()

        let relaunched = makeServices()
        XCTAssertEqual(relaunched.model.prompt, .focusEnded)
        await relaunched.notifications.settle()
        let shown = try XCTUnwrap(center.onlyDelivered)
        XCTAssertEqual(shown.content.categoryIdentifier, NotificationService.Category.focusEnd)
        XCTAssertEqual(
            shown.content.userInfo[NotificationResponse.phaseIDKey] as? TimeInterval, start.timeIntervalSinceReferenceDate,
            "the prompt belongs to the restored focus"
        )
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, start + focus + TimerProfile.defaultNudgeInterval)
        XCTAssertTrue(relaunched.appNap.isHolding)
    }

    func testColdLaunchActionRunsAfterTheLaunchSync() async throws {
        var services: AppServices? = makeServices()
        services?.model.startFocus()
        await services?.notifications.settle()
        services?.model.shutdown()
        services = nil
        h.clock.advance(by: focus + 60)
        center.deliverDue()
        let banner = try XCTUnwrap(center.onlyDelivered)

        // The response arrives once the notification delegate exists, before the model does.
        let notifications = makeNotifications()
        let response = Task { await center.respond(.startBreak, to: banner) }
        for _ in 0..<10 { await Task.yield() }

        let relaunched = makeServices(notifications: notifications)
        await response.value
        XCTAssertEqual(relaunched.model.snapshot.phase, .shortBreak)
        XCTAssertEqual(relaunched.model.completedToday, 1)
    }

    // MARK: System events

    func testWakeReconcilesTheModel() async throws {
        let services = makeServices()
        services.model.startFocus()
        await services.notifications.settle()
        // Asleep across the end: no timer fires, but the system delivers on wake.
        h.clock.advance(by: focus + 30)
        center.deliverDue()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(services.model.snapshot.status, .overtime(since: start + focus))
        XCTAssertEqual(services.model.prompt, .focusEnded)
        await services.notifications.settle()
        XCTAssertEqual(focusEndBanners, 1)
    }

    // MARK: Lifetime

    func testReleasingTheServicesReleasesEverything() async {
        var services: AppServices? = makeServices()
        services?.model.startFocus()
        await services?.notifications.settle()
        services?.model.shutdown()
        weak let model = services?.model
        weak let notifications = services?.notifications
        weak let systemEvents = services?.systemEvents
        services = nil
        XCTAssertNil(model)
        XCTAssertNil(notifications)
        XCTAssertNil(systemEvents)
        XCTAssertEqual(activities.active, 0, "the App Nap activity ended with the guard")
    }
}
