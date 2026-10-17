import PomodoroCore
import UserNotifications
import XCTest
@testable import Pomodoro

/// Behaves like the system center: requests with a trigger wait until `deliverDue()`, requests
/// without one are delivered at once, and an identifier replaces its earlier request.
@MainActor
private final class FakeNotificationCenter: NotificationCenterClient {
    struct Pending {
        var request: UNNotificationRequest
        var fireDate: Date
    }

    var onResponse: (@MainActor (NotificationResponse) -> Void)?
    private(set) var authorizationRequests: [UNAuthorizationOptions] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var pending: [String: Pending] = [:]
    private(set) var delivered: [String: UNNotificationRequest] = [:]
    private(set) var addCount = 0
    var authorizationCompletion: (@MainActor @Sendable (Bool) -> Void)?
    /// Models the system dropping requests added before notifications were allowed.
    var isAuthorized = true
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

    func add(_ request: UNNotificationRequest) {
        addCount += 1
        guard isAuthorized else { return }
        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger {
            pending[request.identifier] = Pending(request: request, fireDate: clock.now + trigger.timeInterval)
        } else {
            pending[request.identifier] = nil
            delivered[request.identifier] = request
        }
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
            delivered[id] = entry.request
        }
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
        service = NotificationService(center: center, clock: clock)
    }

    /// Runs an engine call and syncs, as the app model does after every call.
    private func act(_ body: (TimerEngine) -> [TimerEvent]) {
        service.sync(with: engine, events: body(engine))
    }

    /// Moves time on, lets the system deliver what is due, then reconciles in-app.
    private func elapse(_ interval: TimeInterval) {
        clock.advance(by: interval)
        center.deliverDue()
        act { $0.reconcile() }
    }

    private func grant() {
        center.authorizationCompletion?(true)
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

    func testFocusStartPreSchedulesASilentFocusEndAtTheBoundary() throws {
        act { $0.start() }
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, engine.nextBoundary)
        XCTAssertEqual(entry.fireDate, t0 + focus)
        XCTAssertTrue(NotificationService.identifiers.contains(entry.request.identifier))
        XCTAssertEqual(entry.request.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(entry.request.content.title, "Focus complete")
        XCTAssertNil(entry.request.content.sound, "the chime is played in-app")
        XCTAssertEqual(entry.request.content.threadIdentifier, NotificationService.threadIdentifier)
    }

    func testAutoStartedTransitionsHaveNoActions() {
        let content = NotificationService.content(for: .phaseEnd(.focus, autoStarts: true))
        XCTAssertEqual(content.categoryIdentifier, "")
        XCTAssertEqual(NotificationService.content(for: .phaseEnd(.shortBreak, autoStarts: true)).categoryIdentifier, "")
        XCTAssertEqual(NotificationService.content(for: .phaseEnd(.longBreak, autoStarts: false)).categoryIdentifier, "BREAK_END")
    }

    func testAutoStartBreaksSchedulesTheNoActionVariant() throws {
        engine.configuration.autoStartBreaks = true
        act { $0.start() }
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).request.content.categoryIdentifier, "")
    }

    // MARK: Authorization

    func testAuthorizationIsRequestedOnTheFirstFocusOnly() {
        XCTAssertTrue(center.authorizationRequests.isEmpty, "requested at launch")
        act { $0.start(phase: .shortBreak) }
        XCTAssertTrue(center.authorizationRequests.isEmpty, "requested for a break")
        act { $0.start() }
        XCTAssertEqual(center.authorizationRequests, [.alert])
        grant()
        act { $0.stopAndLog() }
        act { $0.start() }
        XCTAssertEqual(center.authorizationRequests.count, 1)
    }

    func testGrantResendsTheRequestDroppedBeforeAuthorization() throws {
        center.isAuthorized = false
        act { $0.start() }
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(by: 30)
        center.isAuthorized = true
        grant()
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus, "re-sent with the remaining interval")
    }

    // MARK: Reschedule on every action

    func testPauseCancelsAndResumeReschedulesAtTheShiftedEnd() throws {
        act { $0.start() }
        clock.advance(by: 60)
        act { $0.pause() }
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(by: 120)
        act { $0.resume() }
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).fireDate, t0 + focus + 120)
    }

    func testExtendReplacesThePendingRequest() throws {
        act { $0.start() }
        let id = try XCTUnwrap(center.onlyPending).request.identifier
        act { $0.extend(by: 5 * 60) }
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.request.identifier, id, "replaced, not stacked")
        XCTAssertEqual(entry.fireDate, t0 + focus + 5 * 60)
    }

    func testSkipSchedulesTheBreakEnd() throws {
        act { $0.start() }
        clock.advance(by: 60)
        act { $0.skip() }
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.request.content.categoryIdentifier, "BREAK_END")
        XCTAssertEqual(entry.fireDate, t0 + 60 + shortBreak)
    }

    func testResetAndStopCancel() {
        act { $0.start() }
        act { $0.reset() }
        XCTAssertTrue(center.pending.isEmpty)
        act { $0.start() }
        act { $0.stopAndLog() }
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testStartBreakFromRunningFocusReschedules() throws {
        act { $0.start() }
        clock.advance(by: 60)
        act { $0.startBreak() }
        XCTAssertEqual(try XCTUnwrap(center.onlyPending).request.content.categoryIdentifier, "BREAK_END")
    }

    func testUnchangedPlanIsNotResent() {
        act { $0.start() }
        let adds = center.addCount
        clock.advance(by: 60)
        act { $0.reconcile() }
        XCTAssertEqual(center.addCount, adds)
    }

    // MARK: Boundaries and nudges

    func testBoundaryIsLeftToTheSystemAndTheNudgeIsPreScheduled() throws {
        act { $0.start() }
        elapse(focus)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        let nudgeEntry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(nudgeEntry.fireDate, t0 + focus + nudge)
        XCTAssertEqual(nudgeEntry.request.content.title, "Still focusing")
        XCTAssertEqual(nudgeEntry.request.content.categoryIdentifier, "FOCUS_END")
        XCTAssertNotEqual(nudgeEntry.request.identifier, center.onlyDelivered?.identifier)
    }

    func testInAppReconcileWinningTheRaceDoesNotDropTheDueRequest() throws {
        act { $0.start() }
        let id = try XCTUnwrap(center.onlyPending).request.identifier
        clock.advance(by: focus)
        act { $0.reconcile() } // before the system delivers
        XCTAssertNotNil(center.pending[id], "the due request was removed or replaced")
        XCTAssertEqual(center.pending.count, 2)
        center.deliverDue()
        XCTAssertEqual(center.delivered[id]?.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
    }

    func testEachNudgeReplacesThePreviousNotification() throws {
        act { $0.start() }
        elapse(focus)
        elapse(nudge)
        XCTAssertEqual(center.onlyDelivered?.content.title, "Still focusing")
        XCTAssertEqual(center.onlyDelivered?.content.body, "10 min over. Take a break?")
        XCTAssertEqual(center.onlyPending?.fireDate, t0 + focus + 2 * nudge)
        elapse(nudge)
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertEqual(center.onlyDelivered?.content.body, "20 min over. Take a break?")
    }

    func testNudgesOffSchedulesNothingInOvertime() {
        engine.configuration.nudgeInterval = nil
        act { $0.start() }
        elapse(focus)
        XCTAssertNotNil(center.onlyDelivered)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testFlowModeOffSchedulesNothingWhileAwaitingADecision() {
        engine.configuration.flowMode = false
        act { $0.start() }
        elapse(focus)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testUnscheduledBoundaryIsAnnouncedImmediately() throws {
        // The engine ran before the service saw it, as when state is restored at launch.
        engine.start()
        clock.advance(by: focus + 1)
        act { $0.reconcile() }
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "FOCUS_END")
        XCTAssertEqual(center.onlyPending?.request.content.title, "Still focusing")
    }

    func testAutoStartedBreakKeepsTheFocusEndOnScreen() throws {
        engine.configuration.autoStartBreaks = true
        act { $0.start() }
        elapse(focus)
        XCTAssertEqual(center.onlyDelivered?.content.body, "Your break has started.")
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    func testBreakEndThenStartFocus() throws {
        act { $0.start(phase: .shortBreak) }
        elapse(shortBreak)
        XCTAssertEqual(center.onlyDelivered?.content.categoryIdentifier, "BREAK_END")
        act { $0.start() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "FOCUS_END")
    }

    // MARK: Clearing answered prompts

    func testAnsweringThePromptClearsIt() {
        act { $0.start() }
        elapse(focus)
        act { $0.startBreak() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertEqual(center.onlyPending?.request.content.categoryIdentifier, "BREAK_END")
    }

    func testKeepGoingClearsThePromptAndStopsNudges() {
        act { $0.start() }
        elapse(focus)
        act { $0.keepGoing() }
        XCTAssertTrue(center.delivered.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testExtendInOvertimeClearsThePromptAndSchedulesTheNewEnd() throws {
        act { $0.start() }
        elapse(focus)
        clock.advance(by: 30)
        act { $0.extend(by: 5 * 60) }
        XCTAssertTrue(center.delivered.isEmpty)
        let entry = try XCTUnwrap(center.onlyPending)
        XCTAssertEqual(entry.fireDate, t0 + focus + 30 + 5 * 60)
        XCTAssertEqual(entry.request.content.title, "Focus complete")
    }

    func testPauseInOvertimeKeepsThePromptButCancelsTheNudge() {
        act { $0.start() }
        elapse(focus)
        act { $0.pause() }
        XCTAssertEqual(center.delivered.count, 1)
        XCTAssertTrue(center.pending.isEmpty)
        clock.advance(by: 60)
        act { $0.resume() }
        XCTAssertEqual(center.onlyPending?.fireDate, t0 + focus + 60 + nudge)
    }

    func testResetExactlyAtTheBoundaryDropsTheDueRequest() {
        act { $0.start() }
        clock.advance(by: focus)
        act { $0.reset() }
        center.deliverDue()
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(center.delivered.isEmpty)
    }

    // MARK: Action routing

    private func respond(_ action: NotificationService.Action, category: String) {
        center.onResponse?(NotificationResponse(actionIdentifier: action.rawValue, categoryIdentifier: category))
    }

    func testFocusEndActionsRouteToCommands() {
        let commands = FakeCommands()
        service.commands = commands
        act { $0.start() }
        elapse(focus)
        respond(.startBreak, category: "FOCUS_END")
        respond(.extendFocus, category: "FOCUS_END")
        respond(.keepGoing, category: "FOCUS_END")
        XCTAssertEqual(commands.calls, ["startBreak", "extend:300", "keepGoing"])
    }

    func testBreakEndActionsRouteToCommands() {
        let commands = FakeCommands()
        service.commands = commands
        act { $0.start(phase: .longBreak) }
        respond(.startFocus, category: "BREAK_END")
        respond(.extendBreak, category: "BREAK_END")
        respond(.doneForNow, category: "BREAK_END")
        XCTAssertEqual(commands.calls, ["startFocus", "extend:120", "stopAndLog"])
    }

    func testStaleActionsFromAnotherPhaseAreIgnored() {
        let commands = FakeCommands()
        service.commands = commands
        act { $0.start(phase: .shortBreak) }
        respond(.extendFocus, category: "FOCUS_END")
        act { $0.start() }
        respond(.extendBreak, category: "BREAK_END")
        respond(.doneForNow, category: "BREAK_END")
        act { $0.stopAndLog() }
        respond(.startBreak, category: "FOCUS_END")
        XCTAssertTrue(commands.calls.isEmpty)
    }

    func testDefaultAndDismissActionsDoNothing() {
        let commands = FakeCommands()
        service.commands = commands
        act { $0.start() }
        center.onResponse?(NotificationResponse(actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: "FOCUS_END"))
        center.onResponse?(NotificationResponse(actionIdentifier: UNNotificationDismissActionIdentifier, categoryIdentifier: "FOCUS_END"))
        XCTAssertTrue(commands.calls.isEmpty)
    }
}
