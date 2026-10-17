import PomodoroCore
import UserNotifications
import XCTest
@testable import Pomodoro

/// Behaves like the system center: requests with a trigger wait until they're due, requests
/// without one are delivered at once, and an identifier replaces its earlier request, pending or
/// delivered. The system delivers due requests on its own schedule: `deliverDue()` forces it, and a
/// pending-queue check does it too unless `deliveryLag` holds it back. `fireDue()` models a fired
/// trigger whose delivery is still on its way: removing it does nothing, and `land()` delivers it.
@MainActor
final class FakeNotificationCenter: NotificationCenterClient {
    struct Pending {
        var request: UNNotificationRequest
        var fireDate: Date
    }

    var onResponse: (@MainActor (NotificationResponse) async -> Void)?
    var shouldPresent: (@MainActor (DeliveredNotice) -> Bool)?
    private(set) var authorizationRequests: [UNAuthorizationOptions] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var pending: [String: Pending] = [:]
    private(set) var delivered: [String: UNNotificationRequest] = [:]
    /// Every banner shown, in order, including one that replaced another.
    private(set) var banners: [UNNotificationRequest] = []
    private(set) var mostOnScreen = 0
    private(set) var addCount = 0
    private(set) var pendingQueries = 0
    private(set) var deliveredQueries = 0
    private(set) var inTransit: [UNNotificationRequest] = []
    /// Whether `land()` asks `shouldPresent` first, as the system does while the app is frontmost.
    var isFrontmost = false
    /// Makes `add` wait for `releaseAdds()` before completing, as the system's completion can.
    var holdsAdds = false
    private var heldAdds: [CheckedContinuation<Void, Never>] = []
    var heldAddCount: Int { heldAdds.count }
    var authorizationCompletion: (@MainActor @Sendable (Bool) -> Void)?
    /// Models the system refusing requests until notifications are allowed.
    var isAuthorized = true
    /// Pending-queue checks that still find a due request undelivered, as when the system is slow.
    var deliveryLag = 0
    private let clock: TestClock

    init(clock: TestClock) {
        self.clock = clock
    }

    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        authorizationRequests.append(options)
        authorizationCompletion = completion
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        addCount += 1
        let accepted = isAuthorized
        if holdsAdds { await withCheckedContinuation { heldAdds.append($0) } }
        guard accepted else { return false }
        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
            pending[request.identifier] = Pending(request: request, fireDate: clock.now + trigger.timeInterval)
        } else {
            pending[request.identifier] = nil
            show(request)
        }
        return true
    }

    func pendingRequestIdentifiers() async -> Set<String> {
        pendingQueries += 1
        if deliveryLag > 0 { deliveryLag -= 1 } else { deliverDue() }
        return Set(pending.keys)
    }

    func deliveredNotices() async -> [DeliveredNotice] {
        deliveredQueries += 1
        return delivered.values.map(DeliveredNotice.init)
    }

    func releaseAdds() {
        let held = heldAdds
        heldAdds = []
        held.forEach { $0.resume() }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        identifiers.forEach { pending[$0] = nil }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        identifiers.forEach { delivered[$0] = nil }
    }

    func deliverDue() {
        for (id, entry) in pending where entry.fireDate <= clock.now {
            pending[id] = nil
            show(entry.request)
        }
    }

    func fireDue() {
        for (id, entry) in pending where entry.fireDate <= clock.now {
            pending[id] = nil
            inTransit.append(entry.request)
        }
    }

    func land() {
        let arriving = inTransit
        inTransit = []
        for request in arriving where !isFrontmost || shouldPresent?(DeliveredNotice(request)) != false {
            show(request)
        }
    }

    func respond(_ action: NotificationService.Action, to request: UNNotificationRequest) async {
        await onResponse?(NotificationResponse(actionIdentifier: action.rawValue, content: request.content))
    }

    private func show(_ request: UNNotificationRequest) {
        delivered[request.identifier] = request
        banners.append(request)
        mostOnScreen = max(mostOnScreen, delivered.count)
    }

    var onlyPending: Pending? {
        pending.count == 1 ? pending.values.first : nil
    }

    var onlyDelivered: UNNotificationRequest? {
        delivered.count == 1 ? delivered.values.first : nil
    }
}

@MainActor
private final class FakeCommands: TimerCommandHandling {
    private(set) var calls: [String] = []
    func startBreak() { calls.append("startBreak") }
    func extend(by amount: TimeInterval) { calls.append("extend:\(Int(amount))") }
    func keepGoing() { calls.append("keepGoing") }
    func startFocus() { calls.append("startFocus") }
    func stopAndLog() { calls.append("stopAndLog") }
}

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let focus: TimeInterval = 25 * 60
private let shortBreak: TimeInterval = 5 * 60
private let nudge: TimeInterval = 10 * 60

@MainActor
final class NotificationServiceTests: XCTestCase {
    private var clock: TestClock!
    private var engine: TimerEngine!
    private var center: FakeNotificationCenter!
    private var service: NotificationService!

    override func setUp() async throws {
        clock = TestClock(now: t0)
        engine = TimerEngine(clock: clock)
        center = FakeNotificationCenter(clock: clock)
        service = NotificationService(center: center, clock: clock, pause: { await Task.yield() })
    }

    override func tearDown() async throws {
        XCTAssertLessThanOrEqual(center.mostOnScreen, 1, "two notifications were on screen at once")
    }

    /// Runs an engine call and syncs, as the app model does after every call.
    private func act(_ body: (TimerEngine) -> [TimerEvent]) async {
        service.sync(with: engine, events: body(engine))
        await service.settle()
    }

    /// Moves time on, lets the system deliver what is due, then reconciles in-app.
    private func elapse(_ interval: TimeInterval) async {
        clock.advance(by: interval)
        center.deliverDue()
        await act { $0.reconcile() }
    }

    private func grant() async {
        center.isAuthorized = true
        center.authorizationCompletion?(true)
        await service.settle()
    }

    /// Syncs a reconcile and returns once the service is waiting on the pending queue.
    private func reconcileUntilHandoff() async {
        service.sync(with: engine, events: engine.reconcile())
        while center.pendingQueries == 0 { await Task.yield() }
    }

    // MARK: Categories and content

    func testRegistersBothCategoriesWithTheirActions() {
        let byID = Dictionary(uniqueKeysWithValues: center.categories.map { ($0.identifier, $0) })
        XCTAssertEqual(Set(byID.keys), ["FOCUS_END", "BREAK_END"])
        XCTAssertEqual(byID["FOCUS_END"]?.actions.map(\.title), ["Start break", "+5 min", "Keep going"])
        XCTAssertEqual(byID["FOCUS_END"]?.actions.map(\.identifier), ["START_BREAK", "EXTEND_FOCUS", "KEEP_GOING"])
        XCTAssertEqual(byID["BREAK_END"]?.actions.map(\.title), ["Start focus", "+2 min", "Done for now"])
        XCTAssertEqual(byID["BREAK_END"]?.actions.map(\.identifier), ["START_FOCUS", "EXTEND_BREAK", "DONE_FOR_NOW"])
    }

    func testFocusStartPreSchedulesASilentFocusEndAtTheBoundary() async throws {
        await act { $0.start() }
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, engine.nextBoundary)
        XCTAssertEqual(entry.fireDate, t0 + focus)
        XCTAssertEqual(entry.request.identifier, NotificationService.identifier)
        XCTAssertEqual(entry.request.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(entry.request.content.title, "Focus complete")
        XCTAssertNil(entry.request.content.sound, "the chime is played in-app")
        XCTAssertEqual(entry.request.content.threadIdentifier, NotificationService.threadIdentifier)
        XCTAssertEqual(entry.request.content.userInfo[NotificationResponse.phaseIDKey] as? TimeInterval, t0.timeIntervalSinceReferenceDate)
    }

    func testAutoStartedTransitionsHaveNoActions() {
        XCTAssertEqual(NotificationService.content(for: .phaseEnd(.focus, autoStarts: true)).categoryIdentifier, "")
        XCTAssertEqual(NotificationService.content(for: .phaseEnd(.shortBreak, autoStarts: true)).categoryIdentifier, "")
        XCTAssertEqual(NotificationService.content(for: .phaseEnd(.longBreak, autoStarts: false)).categoryIdentifier, "BREAK_END")
    }

    func testAutoStartBreaksSchedulesTheNoActionVariant() async throws {
        engine.configuration.autoStartBreaks = true
        await act { $0.start() }
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).request.content.categoryIdentifier, "")
    }

    func testPreScheduledBreakEndDoesNotPromiseAnAutoStartedFocus() async throws {
        engine.configuration.autoStartFocus = true
        await act { $0.start(phase: .shortBreak) }
        let content = try XCTUnwrap(center.onlyPending).request.content
        XCTAssertEqual(content.title, "Break's over")
        XCTAssertFalse(content.body.contains("started"), content.body)
    }

    // MARK: Authorization

    func testAuthorizationIsRequestedOnTheFirstFocusOnly() async {
        XCTAssertTrue(center.authorizationRequests.isEmpty, "requested at launch")
        await act { $0.start(phase: .shortBreak) }
        XCTAssertTrue(center.authorizationRequests.isEmpty, "requested for a break")
        await act { $0.start() }
        XCTAssertEqual(center.authorizationRequests, [.alert])
        await grant()
        await act { $0.stopAndLog() }
        await act { $0.start() }
        XCTAssertEqual(center.authorizationRequests.count, 1)
    }

    func testGrantResendsTheRequestRefusedBeforeAuthorization() async throws {
        center.isAuthorized = false
        await act { $0.start() }
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(by: 30)
        await grant()
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus, "re-sent with the remaining interval")
    }

    func testGrantAfterTheBoundaryPostsTheMissedPromptWithNudgesOff() async throws {
        engine.configuration.nudgeInterval = nil
        center.isAuthorized = false
        await act { $0.start() }
        await elapse(focus)
        XCTAssertTrue(center.banners.isEmpty)
        await grant()
        XCTAssertEqual(center.banners.count, 1)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(center.onlyDelivered?.content.body, "Take a break?")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testGrantAfterTheBoundaryPostsTheFocusEndNotJustTheNextNudge() async throws {
        center.isAuthorized = false
        await act { $0.start() }
        await elapse(focus)
        await grant()
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"])
        let nudgeEntry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(nudgeEntry.request.content.title, "Still focusing")
        XCTAssertEqual(nudgeEntry.fireDate, t0 + focus + nudge)
    }

    func testGrantAfterTheDeadlineButBeforeReconcileAnnouncesOnce() async throws {
        center.isAuthorized = false
        await act { $0.start() }
        clock.advance(by: focus + 5)
        await grant()
        clock.advance(by: 1)
        center.deliverDue()
        await act { $0.reconcile() }
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"])
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
    }

    func testGrantAfterThePromptWasAnsweredPostsNothing() async {
        center.isAuthorized = false
        await act { $0.start() }
        await elapse(focus)
        await act { $0.startBreak() }
        await grant()
        XCTAssertTrue(center.banners.isEmpty)
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    /// Grants authorization while a refused `add` is still waiting for its completion.
    private func grantDuringRefusedAdd(_ body: () -> Void) async {
        center.holdsAdds = true
        body()
        while center.heldAddCount == 0 { await Task.yield() }
        center.isAuthorized = true
        center.authorizationCompletion?(true)
        center.holdsAdds = false
        center.releaseAdds()
        await service.settle()
    }

    func testGrantWhileTheScheduledAddIsBeingRefusedResendsIt() async throws {
        center.isAuthorized = false
        await grantDuringRefusedAdd { service.sync(with: engine, events: engine.start()) }
        let entry = try XCTUnwrap(center.onlyPending, "the refused request was never re-sent")
        XCTAssertEqual(entry.fireDate, t0 + focus)
    }

    func testGrantWhileTheImmediatePostIsBeingRefusedPostsIt() async throws {
        engine.configuration.nudgeInterval = nil
        center.isAuthorized = false
        await act { $0.start() }
        clock.advance(by: focus)
        await grantDuringRefusedAdd { service.sync(with: engine, events: engine.reconcile()) }
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"], "the missed prompt was lost")
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
    }

    func testDenialStopsPostingAltogether() async {
        center.isAuthorized = false
        await act { $0.start() }
        center.authorizationCompletion?(false)
        await service.settle()
        let adds = center.addCount
        await elapse(focus)
        await elapse(nudge)
        await act { $0.startBreak() }
        XCTAssertEqual(center.addCount, adds, "kept sending after denial")
        XCTAssertTrue(center.banners.isEmpty)
    }

    // MARK: Reschedule on every action

    func testPauseCancelsAndResumeReschedulesAtTheShiftedEnd() async throws {
        await act { $0.start() }
        clock.advance(by: 60)
        await act { $0.pause() }
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(by: 120)
        await act { $0.resume() }
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, t0 + focus + 120)
    }

    func testExtendReplacesThePendingRequest() async throws {
        await act { $0.start() }
        await act { $0.extend(by: 5 * 60) }
        let entry = try XCTUnwrap(center.onlyPending, "replaced, not stacked")
        XCTAssertEqual(entry.fireDate, t0 + focus + 5 * 60)
    }

    func testSkipSchedulesTheBreakEnd() async throws {
        await act { $0.start() }
        clock.advance(by: 60)
        await act { $0.skip() }
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.request.content.categoryIdentifier, "BREAK_END")
        XCTAssertEqual(entry.fireDate, t0 + 60 + shortBreak)
    }

    func testResetAndStopCancel() async {
        await act { $0.start() }
        await act { $0.reset() }
        XCTAssertTrue(center.pending.isEmpty)
        await act { $0.start() }
        await act { $0.stopAndLog() }
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testStartBreakFromRunningFocusReschedules() async throws {
        await act { $0.start() }
        clock.advance(by: 60)
        await act { $0.startBreak() }
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).request.content.categoryIdentifier, "BREAK_END")
    }

    func testUnchangedPlanIsNotResent() async {
        await act { $0.start() }
        let adds = center.addCount
        clock.advance(by: 60)
        await act { $0.reconcile() }
        XCTAssertEqual(center.addCount, adds)
    }

    func testUnreconciledEngineChangesNothing() async {
        await act { $0.start() }
        let adds = center.addCount
        clock.advance(by: focus)
        engine.configuration.nudgeInterval = 5 * 60
        await act { _ in [] }
        XCTAssertEqual(center.addCount, adds)
        XCTAssertNotNil(center.onlyPending, "the due request was touched before the reconcile")
    }

    // MARK: Boundaries and nudges

    func testBoundaryIsLeftToTheSystemAndTheNudgeIsPreScheduled() async throws {
        await act { $0.start() }
        await elapse(focus)
        XCTAssertEqual(center.banners.count, 1, "re-posted after the system delivered it")
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        let nudgeEntry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(nudgeEntry.fireDate, t0 + focus + nudge)
        XCTAssertEqual(nudgeEntry.request.content.title, "Still focusing")
        XCTAssertEqual(nudgeEntry.request.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(nudgeEntry.request.identifier, center.onlyDelivered?.identifier, "the nudge replaces it on delivery")
    }

    func testReconcileBeforeDeliveryWaitsForTheSystemInsteadOfReplacingIt() async throws {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliveryLag = 3
        await act { $0.reconcile() }
        XCTAssertGreaterThanOrEqual(center.pendingQueries, 4)
        XCTAssertEqual(center.banners.count, 1)
        XCTAssertEqual(center.onlyDelivered?.content.title, "Focus complete")
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
    }

    func testNudgeDeliveredBeforeReconcileReplacesTheFocusEnd() async throws {
        await act { $0.start() }
        await elapse(focus)
        clock.advance(by: nudge)
        center.deliverDue() // the app hasn't reconciled yet
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.onlyDelivered?.content.title, "Still focusing")
        await act { $0.reconcile() }
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete", "Still focusing"], "one banner per boundary")
    }

    func testNudgeDeliveredAfterReconcileReplacesTheFocusEnd() async throws {
        await act { $0.start() }
        await elapse(focus)
        clock.advance(by: nudge)
        center.deliveryLag = 2
        await act { $0.reconcile() }
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete", "Still focusing"])
        XCTAssertEqual(center.onlyPending?.fireDate, t0 + focus + 2 * nudge)
    }

    func testStuckDueRequestIsReplacedByAnImmediatePostNotDropped() async throws {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliveryLag = .max
        await act { $0.reconcile() }
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"])
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
    }

    func testUnchangedSyncsDoNotPostponeTheStuckRequestFallback() async throws {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliveryLag = .max
        await reconcileUntilHandoff()
        var syncs = 0
        while center.banners.isEmpty, syncs < 10 * NotificationService.handoffAttempts {
            service.sync(with: engine, events: engine.reconcile())
            syncs += 1
            await Task.yield()
        }
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"], "the syncs kept restarting the wait")
        await service.settle()
        XCTAssertEqual(center.pendingQueries, NotificationService.handoffAttempts)
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
        for _ in 0..<5 { await act { $0.reconcile() } }
        XCTAssertEqual(center.pendingQueries, NotificationService.handoffAttempts, "kept polling after the fallback")
    }

    func testEachNudgeReplacesThePreviousNotification() async throws {
        await act { $0.start() }
        await elapse(focus)
        await elapse(nudge)
        XCTAssertEqual(center.onlyDelivered?.content.title, "Still focusing")
        XCTAssertEqual(center.onlyDelivered?.content.body, "10 min over. Take a break?")
        XCTAssertEqual(center.onlyPending?.fireDate, t0 + focus + 2 * nudge)
        await elapse(nudge)
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.onlyDelivered?.content.body, "20 min over. Take a break?")
        XCTAssertEqual(center.banners.count, 3)
    }

    func testNudgesOffSchedulesNothingInOvertime() async {
        engine.configuration.nudgeInterval = nil
        await act { $0.start() }
        await elapse(focus)
        XCTAssertNotNil(center.onlyDelivered)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testFlowModeOffSchedulesNothingWhileAwaitingADecision() async {
        engine.configuration.flowMode = false
        await act { $0.start() }
        await elapse(focus)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testUnscheduledBoundaryIsAnnouncedImmediately() async throws {
        // The engine ran before the service saw it, as when state is restored at launch.
        engine.start()
        clock.advance(by: focus + 1)
        await act { $0.reconcile() }
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
    }

    func testAutoStartedBreakKeepsTheFocusEndOnScreen() async throws {
        engine.configuration.autoStartBreaks = true
        await act { $0.start() }
        await elapse(focus)
        XCTAssertEqual(center.onlyDelivered?.content.body, "Your break has started.")
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
        XCTAssertEqual(center.banners.count, 1)
    }

    func testBreakEndThenStartFocus() async throws {
        await act { $0.start(phase: .shortBreak) }
        await elapse(shortBreak)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "BREAK_END")
        await act { $0.start() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "FOCUS_END")
    }

    // MARK: Waking across a boundary

    /// Sleeps through the end of a running break, then wakes with the system and the app racing.
    private func wakeAfterBreak(lateBy late: TimeInterval, systemFirst: Bool) async {
        await act { $0.start(phase: .shortBreak) }
        clock.advance(by: shortBreak + late)
        if systemFirst {
            center.deliverDue()
        } else {
            center.deliveryLag = 1
        }
        await act { $0.reconcile() }
    }

    private func assertBreakPromptOnScreen(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(engine.phase, .shortBreak, "auto-start wasn't skipped", file: file, line: line)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "BREAK_END", file: file, line: line)
        XCTAssertEqual(center.onlyDelivered?.content.body, "Ready to focus?", file: file, line: line)
    }

    func testWakeAfterTheGraceWithAutoStartFocusCorrectsTheDeliveredNotice() async {
        engine.configuration.autoStartFocus = true
        engine.configuration.nudgeInterval = nil
        await wakeAfterBreak(lateBy: 5 * 60, systemFirst: true)
        assertBreakPromptOnScreen()
    }

    func testWakeAfterTheGraceWithAutoStartFocusReplacesTheUndeliveredNotice() async {
        engine.configuration.autoStartFocus = true
        engine.configuration.nudgeInterval = nil
        await wakeAfterBreak(lateBy: 5 * 60, systemFirst: false)
        assertBreakPromptOnScreen()
        XCTAssertEqual(center.banners.count, 1, "the wrong notice was shown first")
    }

    func testWakeAfterTheGraceWithFlowModeOffCorrectsTheNotice() async {
        engine.configuration.autoStartFocus = true
        engine.configuration.flowMode = false
        await wakeAfterBreak(lateBy: 5 * 60, systemFirst: true)
        assertBreakPromptOnScreen()
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testWakeWithinTheGraceKeepsTheAutoStartNotice() async {
        engine.configuration.autoStartFocus = true
        await wakeAfterBreak(lateBy: 30, systemFirst: true)
        XCTAssertEqual(engine.phase, .focus)
        XCTAssertEqual(center.banners.count, 1)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "")
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "FOCUS_END")
    }

    func testWakeAfterBreakWithAutoStartOffShowsTheBreakPromptOnce() async {
        await wakeAfterBreak(lateBy: 5 * 60, systemFirst: false)
        assertBreakPromptOnScreen()
        XCTAssertEqual(center.banners.count, 1)
    }

    func testWakeAcrossAnAutoStartedBreakShowsWhereTheTimerActuallyIs() async {
        engine.configuration.autoStartBreaks = true
        engine.configuration.autoStartFocus = true
        await act { $0.start() }
        clock.advance(by: focus + shortBreak + 5 * 60)
        center.deliverDue()
        await act { $0.reconcile() }
        assertBreakPromptOnScreen()
    }

    func testWakeAcrossFocusEndWithAutoStartOffAnnouncesOnce() async {
        await act { $0.start() }
        clock.advance(by: focus + 25 * 60)
        center.deliverDue()
        await act { $0.reconcile() }
        XCTAssertEqual(center.banners.map(\.content.body), ["Take a break?"])
        XCTAssertEqual(center.onlyPending?.fireDate, t0 + focus + 3 * nudge, "piled-up nudges were sent")
    }

    // MARK: Clearing answered prompts

    func testAnsweringThePromptClearsIt() async {
        await act { $0.start() }
        await elapse(focus)
        await act { $0.startBreak() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    func testKeepGoingClearsThePromptAndStopsNudges() async {
        await act { $0.start() }
        await elapse(focus)
        await act { $0.keepGoing() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testExtendInOvertimeClearsThePromptAndSchedulesTheNewEnd() async throws {
        await act { $0.start() }
        await elapse(focus)
        clock.advance(by: 30)
        await act { $0.extend(by: 5 * 60) }
        XCTAssertTrue(center.delivered.isEmpty)
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus + 30 + 5 * 60)
        XCTAssertEqual(entry.request.content.title, "Focus complete")
    }

    func testPauseInOvertimeKeepsThePromptButCancelsTheNudge() async {
        await act { $0.start() }
        await elapse(focus)
        await act { $0.pause() }
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(by: 60)
        await act { $0.resume() }
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.onlyPending?.fireDate, t0 + focus + 60 + nudge)
    }

    func testResetExactlyAtTheBoundaryDropsTheDueRequest() async {
        await act { $0.start() }
        clock.advance(by: focus)
        await act { $0.reset() }
        center.deliverDue()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.banners.isEmpty)
    }

    func testExtendAtTheBoundaryAfterDeliveryClearsTheBanner() async throws {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliverDue()
        await act { $0.extend(by: 5 * 60) } // reconciles into focusEnded first
        XCTAssertTrue(center.delivered.isEmpty, "the answered prompt stayed on screen")
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus + 5 * 60)
        XCTAssertEqual(entry.request.content.title, "Focus complete")
    }

    func testStopAtTheBoundaryAfterDeliveryClearsTheBanner() async {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliverDue()
        await act { $0.stopAndLog() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testExtendAtTheBoundaryBeforeDeliveryDropsTheDueRequest() async throws {
        await act { $0.start() }
        clock.advance(by: focus)
        await act { $0.extend(by: 5 * 60) }
        center.deliverDue()
        XCTAssertTrue(center.banners.isEmpty, "the answered prompt appeared later")
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, t0 + focus + 5 * 60)
    }

    func testAnswerAfterReconcileButBeforeDeliveryDropsTheDueRequest() async {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliveryLag = .max
        await reconcileUntilHandoff()
        await act { $0.startBreak() }
        center.deliveryLag = 0
        center.deliverDue()
        XCTAssertTrue(center.banners.isEmpty, "the answered prompt appeared later")
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    func testResetAfterReconcileButBeforeDeliveryDropsTheDueRequest() async {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliveryLag = .max
        await reconcileUntilHandoff()
        await act { $0.reset() }
        center.deliveryLag = 0
        center.deliverDue()
        XCTAssertTrue(center.banners.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testUnrelatedSyncDuringTheHandoffKeepsWaiting() async {
        await act { $0.start() }
        clock.advance(by: focus)
        center.deliveryLag = .max
        await reconcileUntilHandoff()
        await act { $0.pause() } // the prompt stays relevant while paused
        center.deliveryLag = 0
        center.deliverDue()
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"])
    }

    /// Fires the focus-end trigger, then runs `body` before the delivery lands mid-cleanup.
    private func cancelAfterTheTriggerFired(_ body: (TimerEngine) -> [TimerEvent]) async {
        await act { $0.start() }
        clock.advance(by: focus)
        center.fireDue()
        service.sync(with: engine, events: body(engine))
        while center.deliveredQueries == 0 { await Task.yield() }
        XCTAssertNotNil(center.inTransit.first, "removing a fired request should do nothing")
        center.land()
        await service.settle()
    }

    func testResetAfterTheTriggerFiredRemovesTheLateDelivery() async {
        await cancelAfterTheTriggerFired { $0.reset() }
        XCTAssertTrue(center.delivered.isEmpty, "the reset prompt stayed in Notification Center")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAnswerAfterTheTriggerFiredRemovesTheLateDelivery() async {
        await cancelAfterTheTriggerFired { $0.startBreak() }
        XCTAssertTrue(center.delivered.isEmpty, "the answered prompt stayed in Notification Center")
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    func testExtendAfterTheTriggerFiredRemovesTheLateDeliveryButNotTheNewEnd() async throws {
        await cancelAfterTheTriggerFired { $0.extend(by: 5 * 60) }
        XCTAssertTrue(center.delivered.isEmpty)
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus + 5 * 60)
        clock.advance(by: 5 * 60)
        center.deliverDue()
        await act { $0.reconcile() }
        XCTAssertEqual(center.onlyDelivered?.content.title, "Focus complete", "the new end was taken for the old one")
    }

    func testLateDeliveryOfAResetPromptIsNotPresentedWhileFrontmost() async {
        center.isFrontmost = true
        await cancelAfterTheTriggerFired { $0.reset() }
        XCTAssertTrue(center.banners.isEmpty, "the reset prompt was presented")
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testOnTimeDeliveryIsPresentedWhileFrontmost() async {
        center.isFrontmost = true
        await act { $0.start() }
        clock.advance(by: focus)
        center.fireDue()
        center.land()
        await act { $0.reconcile() }
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"])
    }

    /// Fires the focus end before the reconcile hands it off, then runs `body` before it lands.
    private func cancelAfterTheHandoff(frontmost: Bool = false, _ body: (TimerEngine) -> [TimerEvent]) async {
        center.isFrontmost = frontmost
        await act { $0.start() }
        clock.advance(by: focus)
        center.fireDue()
        await act { $0.reconcile() }
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing", "the handoff didn't complete")
        XCTAssertNotNil(center.inTransit.first)
        let queries = center.deliveredQueries
        service.sync(with: engine, events: body(engine))
        for _ in 0..<1_000 where center.deliveredQueries == queries { await Task.yield() }
        center.land()
        await service.settle()
    }

    func testResetAfterTheHandoffRemovesTheLateDelivery() async {
        await cancelAfterTheHandoff { $0.reset() }
        XCTAssertTrue(center.delivered.isEmpty, "the reset prompt stayed in Notification Center")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAnswerAfterTheHandoffRemovesTheLateDelivery() async {
        await cancelAfterTheHandoff { $0.startBreak() }
        XCTAssertTrue(center.delivered.isEmpty, "the answered prompt stayed in Notification Center")
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    func testExtendAfterTheHandoffRemovesTheLateDeliveryButNotTheNewEnd() async throws {
        await cancelAfterTheHandoff { $0.extend(by: 5 * 60) }
        XCTAssertTrue(center.delivered.isEmpty)
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus + 5 * 60)
        XCTAssertEqual(entry.request.content.title, "Focus complete")
    }

    func testResetAfterTheHandoffIsNotPresentedWhileFrontmost() async {
        await cancelAfterTheHandoff(frontmost: true) { $0.reset() }
        XCTAssertTrue(center.banners.isEmpty, "the reset prompt was presented")
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testAnswerAfterTheHandoffIsNotPresentedWhileFrontmost() async {
        await cancelAfterTheHandoff(frontmost: true) { $0.startBreak() }
        XCTAssertTrue(center.banners.isEmpty, "the answered prompt was presented")
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testExtendAfterTheHandoffIsNotPresentedWhileFrontmost() async {
        await cancelAfterTheHandoff(frontmost: true) { $0.extend(by: 5 * 60) }
        XCTAssertTrue(center.banners.isEmpty, "the extended prompt was presented")
        XCTAssertTrue(center.delivered.isEmpty)
    }

    func testHandedOffPromptThatStillAppliesLandsAndStays() async {
        center.isFrontmost = true
        await act { $0.start() }
        clock.advance(by: focus)
        center.fireDue()
        await act { $0.reconcile() }
        await act { $0.pause() } // the prompt stays relevant while paused
        center.land()
        await service.settle()
        XCTAssertEqual(center.banners.map(\.content.title), ["Focus complete"])
        XCTAssertEqual(center.onlyDelivered?.content.title, "Focus complete")
        await act { $0.resume() }
        XCTAssertEqual(center.onlyDelivered?.content.title, "Focus complete", "a later sync removed it")
    }

    func testRetiredRequestIsWatchedForABoundedTime() async {
        await act { $0.start() }
        clock.advance(by: focus)
        center.fireDue()
        await act { $0.reset() }
        XCTAssertEqual(center.deliveredQueries, NotificationService.handoffAttempts)
        await act { $0.start() }
        XCTAssertEqual(center.deliveredQueries, NotificationService.handoffAttempts, "kept watching")
    }

    // MARK: Action routing

    private func installCommands() -> FakeCommands {
        let commands = FakeCommands()
        service.commands = commands
        return commands
    }

    func testFocusEndActionsRouteToCommands() async throws {
        let commands = installCommands()
        await act { $0.start() }
        await elapse(focus)
        let prompt = try XCTUnwrap(center.onlyDelivered)
        await center.respond(.startBreak, to: prompt)
        await center.respond(.extendFocus, to: prompt)
        await center.respond(.keepGoing, to: prompt)
        XCTAssertEqual(commands.calls, ["startBreak", "extend:300", "keepGoing"])
    }

    func testBreakEndActionsRouteToCommands() async throws {
        let commands = installCommands()
        await act { $0.start(phase: .longBreak) }
        let prompt = try XCTUnwrap(center.onlyPending).request
        await center.respond(.startFocus, to: prompt)
        await center.respond(.extendBreak, to: prompt)
        await center.respond(.doneForNow, to: prompt)
        XCTAssertEqual(commands.calls, ["startFocus", "extend:120", "stopAndLog"])
    }

    func testResponseCompletesOnlyAfterTheCommandRuns() async throws {
        let commands = installCommands()
        await act { $0.start() }
        await elapse(focus)
        let prompt = try XCTUnwrap(center.onlyDelivered)
        await center.respond(.startBreak, to: prompt)
        XCTAssertEqual(commands.calls, ["startBreak"], "completed before the command was dispatched")
    }

    func testColdLaunchResponseIsHeldUntilTheRestoredEngineIsSynced() async {
        let commands = installCommands()
        // Restored from the previous launch, past its end; the service hasn't seen it yet.
        engine.start()
        clock.advance(by: focus + 1)
        let center = center!
        let response = Task {
            let prompt = NotificationService.request(.phaseEnd(.focus, autoStarts: false), phaseID: t0, trigger: nil)
            await center.respond(.startBreak, to: prompt)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(commands.calls.isEmpty, "handled before the engine was synced")
        await act { $0.reconcile() }
        await response.value
        XCTAssertEqual(commands.calls, ["startBreak"])
    }

    func testStaleActionsFromAnotherPhaseAreIgnored() async throws {
        let commands = installCommands()
        await act { $0.start(phase: .shortBreak) }
        let breakPrompt = try XCTUnwrap(center.onlyPending).request
        await act { $0.start() }
        let focusPrompt = try XCTUnwrap(center.onlyPending).request
        await center.respond(.extendBreak, to: breakPrompt)
        await center.respond(.doneForNow, to: breakPrompt)
        await act { $0.stopAndLog() }
        await center.respond(.startBreak, to: focusPrompt)
        XCTAssertTrue(commands.calls.isEmpty)
    }

    func testActionFromAnEarlierSessionOfTheSamePhaseIsIgnored() async throws {
        let commands = installCommands()
        await act { $0.start() }
        await elapse(focus)
        let oldPrompt = try XCTUnwrap(center.onlyDelivered)
        await act { $0.startBreak() }
        clock.advance(by: 60)
        await act { $0.start() }
        await center.respond(.extendFocus, to: oldPrompt)
        XCTAssertTrue(commands.calls.isEmpty)
        let newPrompt = try XCTUnwrap(center.onlyPending).request
        await center.respond(.extendFocus, to: newPrompt)
        XCTAssertEqual(commands.calls, ["extend:300"])
    }

    func testActionWithAMismatchedCategoryIsIgnored() async {
        let commands = installCommands()
        await act { $0.start() }
        let response = NotificationResponse(actionIdentifier: "START_BREAK", categoryIdentifier: "BREAK_END", phaseID: t0.timeIntervalSinceReferenceDate)
        await center.onResponse?(response)
        XCTAssertTrue(commands.calls.isEmpty)
    }

    func testDefaultAndDismissActionsDoNothing() async throws {
        let commands = installCommands()
        await act { $0.start() }
        let prompt = try XCTUnwrap(center.onlyPending).request
        await center.onResponse?(NotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, content: prompt.content))
        await center.onResponse?(NotificationResponse(actionIdentifier: UNNotificationDismissActionIdentifier, content: prompt.content))
        XCTAssertTrue(commands.calls.isEmpty)
    }
}
