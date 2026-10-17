import Foundation
import PomodoroCore
import UserNotifications

/// What a notification action asks the timer to do. The app model implements this so an action
/// goes through the same path as the popover buttons (sounds, logging, persistence).
@MainActor
protocol TimerCommandHandling: AnyObject {
    func startBreak()
    func extend(by amount: TimeInterval)
    func keepGoing()
    func startFocus()
    func stopAndLog()
}

/// Mirrors the timer into the notification center.
///
/// The next boundary (phase end, or the next overtime nudge) is always pre-scheduled with a
/// time-interval trigger, so the banner appears on time even while the app is napping. Call
/// `sync(with:events:)` after every engine call, including `reconcile`.
///
/// Notifications carry no sound. The app plays the chime through `SoundService` instead, which
/// honours the chosen sound, the master volume and *None*, and still chimes when the user has
/// turned banners off. `AppNapGuard` keeps that in-app chime on time.
///
/// Every request uses one identifier, so the system itself keeps at most one of our
/// notifications in Notification Center: a delivery replaces whatever was there. The risk with a
/// single identifier is the opposite one, replacing a request that is due but not yet delivered,
/// so that nothing appears. Three rules rule that out:
/// - When the engine passes a boundary the system was asked to announce, the successor is added
///   only after the pending queue confirms that request has been delivered (`waitUntilDelivered`).
/// - A request without a trigger is posted only when nothing reached the screen for the boundary
///   (it was never scheduled, or refused before authorization) or what did says the wrong thing
///   after reconcile. Posting delivers it, so it can't leave the boundary unannounced.
/// - A request is removed only when its prompt no longer applies: answered, reset, stopped, or
///   the phase changed. Then both the pending and the delivered copy go. The system ignores the
///   removal once the trigger has fired, so a request cancelled at its boundary is retired: for
///   the next `handoffAttempts` checks a late delivery of it is hidden if the app is frontmost
///   and removed from Notification Center otherwise. The same goes for a handed-off request
///   whose prompt is cleared, since it may have fired without being delivered yet.
///
/// All center calls run in order on one task, so a later sync never overtakes an earlier one.
@MainActor
final class NotificationService {
    enum Category {
        static let focusEnd = "FOCUS_END"
        static let breakEnd = "BREAK_END"
    }

    enum Action: String, CaseIterable {
        case startBreak = "START_BREAK"
        case extendFocus = "EXTEND_FOCUS"
        case keepGoing = "KEEP_GOING"
        case startFocus = "START_FOCUS"
        case extendBreak = "EXTEND_BREAK"
        case doneForNow = "DONE_FOR_NOW"

        var title: String {
            switch self {
            case .startBreak: "Start break"
            case .extendFocus: "+5 min"
            case .keepGoing: "Keep going"
            case .startFocus: "Start focus"
            case .extendBreak: "+2 min"
            case .doneForNow: "Done for now"
            }
        }

        var category: String {
            switch self {
            case .startBreak, .extendFocus, .keepGoing: Category.focusEnd
            case .startFocus, .extendBreak, .doneForNow: Category.breakEnd
            }
        }
    }

    /// What a notification announces. `autoStarts` means the next phase begins without the user.
    enum Announcement: Equatable {
        case phaseEnd(TimerPhase, autoStarts: Bool)
        case nudge(TimerPhase, overtime: TimeInterval)
    }

    static let identifier = "dev.krishna.pomodoro.prompt"
    static let threadIdentifier = "dev.krishna.pomodoro.timer"
    static let authorizationOptions: UNAuthorizationOptions = [.alert]
    static let focusExtension: TimeInterval = 5 * 60
    static let breakExtension: TimeInterval = 2 * 60
    /// How many times the pending queue is checked before a stuck due request is replaced by an
    /// immediate post, and the delivered list for a retired one. With the default pause that is
    /// about ten seconds. The budget belongs to the request, so syncs in between don't extend it.
    nonisolated static let handoffAttempts = 40

    static var categories: Set<UNNotificationCategory> {
        func category(_ id: String, _ actions: [Action]) -> UNNotificationCategory {
            UNNotificationCategory(
                identifier: id,
                actions: actions.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: []) },
                intentIdentifiers: []
            )
        }
        return [
            category(Category.focusEnd, [.startBreak, .extendFocus, .keepGoing]),
            category(Category.breakEnd, [.startFocus, .extendBreak, .doneForNow]),
        ]
    }

    weak var commands: (any TimerCommandHandling)?

    private enum Authorization { case notRequested, requesting, granted, denied }

    private struct Request: Equatable {
        var announcement: Announcement
        var phaseID: Date?
        /// The fire date of a scheduled request, or when a prompt was observed.
        var date: Date
    }

    /// The announcement that should be on screen now.
    private struct Prompt {
        var serial: Int
        var request: Request
    }

    private struct InFlight {
        var request: Request
        var accepted: Bool
        var checksLeft = NotificationService.handoffAttempts
    }

    /// Cancelled at or just before its boundary, so it may still be delivered.
    private struct Retired {
        var request: Request
        var checksLeft = NotificationService.handoffAttempts
    }

    private struct Shown {
        var serial: Int
        var announcement: Announcement
    }

    private enum Handoff { case delivered, superseded, timedOut }

    private let center: any NotificationCenterClient
    private let clock: any TimeSource
    private let pause: @MainActor () async -> Void
    private var authorization = Authorization.notRequested

    // What the engine wants, as of the latest sync.
    private var syncedAt = Date.distantPast
    private var prompt: Prompt?
    private var next: Request?
    private var serial = 0
    private var phase = TimerPhase.idle
    private var phaseID: Date?

    // What the system has been told.
    private var inFlight: InFlight?
    private var onScreen: Shown?
    /// A prompt whose immediate post was refused, so it isn't retried until authorization changes.
    private var refusedSerial: Int?
    private var retired: Retired?
    /// The last due request handed off to the system. Leaving the pending queue only means its
    /// trigger fired, so it is kept until it's retired in case it's still on its way.
    private var issued: Request?

    private var work: Task<Void, Never>?
    private var dirty = false
    private var bootstrapped = false
    private var heldResponses: [CheckedContinuation<Void, Never>] = []

    init(
        center: any NotificationCenterClient,
        clock: any TimeSource = SystemClock(),
        pause: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
    ) {
        self.center = center
        self.clock = clock
        self.pause = pause
        center.setNotificationCategories(Self.categories)
        center.onResponse = { [weak self] response in await self?.handle(response) }
        center.shouldPresent = { [weak self] notice in self?.isRetired(notice) != true }
    }

    // MARK: - Engine

    func sync(with engine: TimerEngine, events: [TimerEvent] = []) {
        let now = clock.now
        phase = engine.phase
        phaseID = engine.state.phaseStartedAt
        defer { finishBootstrap() }
        if events.contains(.phaseStarted(.focus)) { requestAuthorizationIfNeeded() }

        // Not reconciled yet (a configuration change, say). The reconcile that follows syncs again.
        if let boundary = engine.nextBoundary, boundary <= now { return }

        syncedAt = now
        if events.contains(where: \.isAnnouncement) {
            prompt = observedAnnouncement(engine, events: events).map { announcement in
                serial += 1
                return Prompt(serial: serial, request: Request(announcement: announcement, phaseID: engine.state.phaseStartedAt, date: now))
            }
        } else if let current = prompt, !isRelevant(current, engine) {
            prompt = nil
        }
        next = plannedRequest(engine, now: now)
        kick()
    }

    /// Returns once the notification center reflects the latest sync.
    func settle() async {
        while let task = work { await task.value }
    }

    // MARK: - Responses

    func handle(_ response: NotificationResponse) async {
        // A cold launch from an action can deliver it before the restored engine has been synced.
        if !bootstrapped { await withCheckedContinuation { heldResponses.append($0) } }
        dispatch(response)
    }

    private func dispatch(_ response: NotificationResponse) {
        guard let commands, let action = Action(rawValue: response.actionIdentifier) else { return }
        // A stale notification (another phase, or an earlier session of this one) must not act on the current one.
        guard response.categoryIdentifier == action.category,
              let phaseID, response.phaseID == phaseID.timeIntervalSinceReferenceDate
        else { return }
        switch action {
        case .startBreak, .extendFocus, .keepGoing:
            guard phase == .focus else { return }
        case .startFocus, .extendBreak, .doneForNow:
            guard phase.isBreak else { return }
        }
        switch action {
        case .startBreak: commands.startBreak()
        case .extendFocus: commands.extend(by: Self.focusExtension)
        case .keepGoing: commands.keepGoing()
        case .startFocus: commands.startFocus()
        case .extendBreak: commands.extend(by: Self.breakExtension)
        case .doneForNow: commands.stopAndLog()
        }
    }

    private func finishBootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let held = heldResponses
        heldResponses = []
        held.forEach { $0.resume() }
    }

    // MARK: - Content

    static func content(for announcement: Announcement) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = threadIdentifier
        content.sound = nil
        switch announcement {
        case .phaseEnd(.focus, let autoStarts):
            content.title = "Focus complete"
            content.body = autoStarts ? "Your break has started." : "Take a break?"
            content.categoryIdentifier = autoStarts ? "" : Category.focusEnd
        case .phaseEnd(_, let autoStarts):
            // Pre-scheduled before the engine decides: it skips the auto-start after a late wake.
            content.title = "Break's over"
            content.body = autoStarts ? "Time to focus." : "Ready to focus?"
            content.categoryIdentifier = autoStarts ? "" : Category.breakEnd
        case .nudge(.focus, let overtime):
            content.title = "Still focusing"
            content.body = "\(minutes(overtime)) min over. Take a break?"
            content.categoryIdentifier = Category.focusEnd
        case .nudge(_, let overtime):
            content.title = "Break is running long"
            content.body = "\(minutes(overtime)) min over. Ready to focus?"
            content.categoryIdentifier = Category.breakEnd
        }
        return content
    }

    static func request(_ announcement: Announcement, phaseID: Date?, date: Date? = nil, trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        let content = content(for: announcement)
        if let phaseID { content.userInfo[NotificationResponse.phaseIDKey] = phaseID.timeIntervalSinceReferenceDate }
        if let date { content.userInfo[DeliveredNotice.dateKey] = date.timeIntervalSinceReferenceDate }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    /// Same title and actions. A nudge's minute count can drift across a late delivery, which
    /// isn't worth a second banner.
    private static func sameMessage(_ a: Announcement, _ b: Announcement) -> Bool {
        let (x, y) = (content(for: a), content(for: b))
        return x.title == y.title && x.categoryIdentifier == y.categoryIdentifier
    }

    private static func minutes(_ interval: TimeInterval) -> Int {
        max(1, Int((interval / 60).rounded()))
    }

    // MARK: - Desired state

    /// Waiting on the user after a phase end.
    private func isAwaitingUser(_ engine: TimerEngine) -> Bool {
        engine.phase != .idle && engine.state.endDelivered && !engine.state.nudgesSilenced
    }

    private func isRelevant(_ prompt: Prompt, _ engine: TimerEngine) -> Bool {
        guard engine.phase != .idle, engine.state.phaseStartedAt == prompt.request.phaseID else { return false }
        if case .phaseEnd(_, autoStarts: true) = prompt.request.announcement { return true }
        return isAwaitingUser(engine)
    }

    /// The announcement for a boundary the engine just passed, from its state after the call.
    private func observedAnnouncement(_ engine: TimerEngine, events: [TimerEvent]) -> Announcement? {
        let config = engine.configuration
        switch events.last(where: \.isAnnouncement) {
        case .nudge(let overtime)?:
            return isAwaitingUser(engine) ? .nudge(engine.phase, overtime: overtime) : nil
        case .focusEnded?:
            if isAwaitingUser(engine) { return .phaseEnd(engine.phase, autoStarts: false) }
            let autoStarted = engine.status == .running && engine.phase.isBreak && config.autoStartBreaks
            return autoStarted ? .phaseEnd(.focus, autoStarts: true) : nil
        case .breakEnded?:
            if isAwaitingUser(engine) { return .phaseEnd(engine.phase, autoStarts: false) }
            // The ended break's kind isn't kept, and doesn't change the wording.
            let autoStarted = engine.status == .running && engine.phase == .focus && config.autoStartFocus
            return autoStarted ? .phaseEnd(.shortBreak, autoStarts: true) : nil
        default:
            return nil
        }
    }

    private func plannedRequest(_ engine: TimerEngine, now: Date) -> Request? {
        guard let boundary = engine.nextBoundary, boundary > now else { return nil }
        let id = engine.state.phaseStartedAt
        switch engine.status {
        case .running:
            let config = engine.configuration
            let autoStarts = engine.phase == .focus ? config.autoStartBreaks : config.autoStartFocus
            return Request(announcement: .phaseEnd(engine.phase, autoStarts: autoStarts), phaseID: id, date: boundary)
        case .overtime:
            guard let end = engine.state.phaseEndDate else { return nil }
            return Request(announcement: .nudge(engine.phase, overtime: boundary.timeIntervalSince(end)), phaseID: id, date: boundary)
        case .paused, .awaitingDecision:
            return nil
        }
    }

    // MARK: - Applying it

    private func kick() {
        dirty = true
        guard work == nil else { return }
        work = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while dirty {
            dirty = false
            await apply()
        }
        work = nil
    }

    private func apply() async {
        // 1. A request whose boundary the engine has passed may still sit in the pending queue.
        if let due = inFlight, due.request.date <= syncedAt {
            if let prompt, prompt.request.date >= due.request.date {
                if due.accepted, Self.sameMessage(due.request.announcement, prompt.request.announcement) {
                    switch await waitUntilDelivered() {
                    case .delivered:
                        onScreen = Shown(serial: prompt.serial, announcement: due.request.announcement)
                        issued = due.request
                    case .superseded: return
                    case .timedOut: break
                    }
                }
                // Otherwise nothing reached the screen, or it says the wrong thing; step 2 replaces it.
            } else {
                // Answered, reset or stopped at the boundary.
                retire(due)
                center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
                center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
                onScreen = nil
            }
            inFlight = nil
        }

        // 2. Post the prompt now if nothing scheduled delivered it. This replaces any pending request.
        if let prompt, refusedSerial != prompt.serial, !isShowing(prompt) {
            inFlight = nil
            switch await post(prompt.request, trigger: nil) {
            case true?:
                onScreen = Shown(serial: prompt.serial, announcement: prompt.request.announcement)
            case false?:
                onScreen = nil
                refusedSerial = prompt.serial
            case nil:
                onScreen = nil
            }
        }

        // 3. Pre-schedule the next boundary. Step 1 has already resolved any due request.
        let replaced = inFlight
        if replaced?.request != next {
            if let next {
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, next.date.timeIntervalSince(clock.now)), repeats: false)
                inFlight = await post(next, trigger: trigger).map { InFlight(request: next, accepted: $0) }
            } else if replaced != nil {
                center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
                inFlight = nil
            }
            // The replaced request may have fired just before the call above.
            if let replaced, replaced.request.date <= clock.now + 1 {
                retire(replaced)
                if prompt == nil { center.removeDeliveredNotifications(withIdentifiers: [Self.identifier]) }
            }
        }

        // 4. Clear a prompt that no longer applies.
        if prompt == nil, onScreen != nil {
            if let issued, retired == nil { retired = Retired(request: issued) }
            issued = nil
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            onScreen = nil
        }

        // 5. Catch a retired request that is delivered after all.
        await sweepRetired()
    }

    private func isShowing(_ prompt: Prompt) -> Bool {
        guard let onScreen, onScreen.serial == prompt.serial else { return false }
        return Self.sameMessage(onScreen.announcement, prompt.request.announcement)
    }

    private func waitUntilDelivered() async -> Handoff {
        while (inFlight?.checksLeft ?? 0) > 0 {
            inFlight?.checksLeft -= 1
            let pending = await center.pendingRequestIdentifiers()
            if !pending.contains(Self.identifier) { return .delivered }
            await pause()
            if dirty { return .superseded }
        }
        return .timedOut
    }

    private func retire(_ replaced: InFlight) {
        if replaced.accepted { retired = Retired(request: replaced.request) }
    }

    private func isRetired(_ notice: DeliveredNotice) -> Bool {
        func matches(_ request: Request?) -> Bool {
            guard let request else { return false }
            return notice.phaseID == request.phaseID?.timeIntervalSinceReferenceDate
                && notice.date == request.date.timeIntervalSinceReferenceDate
        }
        guard notice.identifier == Self.identifier, matches(retired?.request) else { return false }
        return !matches(next) && !matches(inFlight?.request)
    }

    private func sweepRetired() async {
        while (retired?.checksLeft ?? 0) > 0 {
            retired?.checksLeft -= 1
            if await center.deliveredNotices().contains(where: isRetired) {
                center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
                retired = nil
                // It replaced whatever was showing.
                if onScreen != nil {
                    onScreen = nil
                    dirty = true
                }
                return
            }
            await pause()
            if dirty { return }
        }
        retired = nil
    }

    /// `nil` when the request was refused but authorization was granted meanwhile, so it should be
    /// sent again rather than recorded as refused.
    private func post(_ request: Request, trigger: UNNotificationTrigger?) async -> Bool? {
        guard authorization != .denied else { return false }
        let before = authorization
        let accepted = await center.add(Self.request(request.announcement, phaseID: request.phaseID, date: request.date, trigger: trigger))
        if !accepted, before != .granted, authorization == .granted { return nil }
        return accepted
    }

    private func requestAuthorizationIfNeeded() {
        guard authorization == .notRequested else { return }
        authorization = .requesting
        center.requestAuthorization(options: Self.authorizationOptions) { [weak self] granted in
            guard let self else { return }
            authorization = granted ? .granted : .denied
            guard granted else { return }
            // Requests refused before the grant are sent again, including a prompt whose boundary has
            // passed. One whose refusal is still on its way is handled by `post`.
            refusedSerial = nil
            if inFlight?.accepted == false { inFlight = nil }
            kick()
        }
    }
}

private extension TimerEvent {
    var isAnnouncement: Bool {
        switch self {
        case .focusEnded, .breakEnded, .nudge: true
        case .phaseStarted, .sessionRecorded: false
        }
    }
}
