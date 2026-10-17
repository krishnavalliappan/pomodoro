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
/// Two identifiers take turns. A request whose fire date has passed may not have been delivered
/// yet (the in-app reconcile can win that race by milliseconds), so it is never removed or
/// replaced; the next request goes in the other slot. When a notification is delivered the one
/// in the other slot is cleared, so at most one is ever on screen.
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
    }

    /// What a notification announces. Equatable so an unchanged plan isn't re-sent.
    enum Announcement: Equatable {
        case phaseEnd(TimerPhase, autoStarts: Bool)
        case nudge(TimerPhase, overtime: TimeInterval)
    }

    static let identifiers = ["dev.krishna.pomodoro.boundary.0", "dev.krishna.pomodoro.boundary.1"]
    static let threadIdentifier = "dev.krishna.pomodoro.timer"
    static let authorizationOptions: UNAuthorizationOptions = [.alert]
    static let focusExtension: TimeInterval = 5 * 60
    static let breakExtension: TimeInterval = 2 * 60

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

    private struct Plan: Equatable {
        var fireDate: Date
        var announcement: Announcement
        var slot: Int
    }

    private let center: any NotificationCenterClient
    private let clock: any TimeSource
    private var authorization = Authorization.notRequested
    private var pending: Plan?
    /// The slot of the latest notification that is on screen (or about to be).
    private var deliveredSlot: Int?
    private var phase = TimerPhase.idle

    init(center: any NotificationCenterClient, clock: any TimeSource = SystemClock()) {
        self.center = center
        self.clock = clock
        center.setNotificationCategories(Self.categories)
        center.onResponse = { [weak self] response in self?.handle(response) }
    }

    // MARK: - Engine

    func sync(with engine: TimerEngine, events: [TimerEvent] = []) {
        let now = clock.now
        phase = engine.phase
        if events.contains(.phaseStarted(.focus)) { requestAuthorizationIfNeeded() }

        let announced = events.contains { $0.isAnnouncement }
        if let due = pending, due.fireDate <= now {
            pending = nil
            if announced {
                // The system delivers it (or just did); it replaces whatever is in the other slot.
                markDelivered(slot: due.slot)
            } else {
                // Due but not announced: the engine was reset at the boundary.
                center.removePendingNotificationRequests(withIdentifiers: [Self.identifiers[due.slot]])
                center.removeDeliveredNotifications(withIdentifiers: [Self.identifiers[due.slot]])
            }
        } else if announced, isAwaitingUser(engine), let announcement = currentAnnouncement(engine, events: events) {
            // Nothing was pre-scheduled for this boundary (state restored at launch, or the
            // request was refused before authorization), so announce it now.
            cancelPending()
            let slot = nextSlot
            center.add(Self.request(announcement, slot: slot, trigger: nil))
            markDelivered(slot: slot)
        }

        // The user has answered the prompt (or there never was one), so clear it from the screen.
        if !announced, !isAwaitingUser(engine), deliveredSlot != nil {
            center.removeDeliveredNotifications(withIdentifiers: Self.identifiers)
            deliveredSlot = nil
        }

        schedule(plannedAnnouncement(engine, now: now), now: now)
    }

    // MARK: - Responses

    func handle(_ response: NotificationResponse) {
        guard let commands, let action = Action(rawValue: response.actionIdentifier) else { return }
        // A stale notification from an earlier phase must not act on the current one.
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

    // MARK: - Content

    static func content(for announcement: Announcement) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = threadIdentifier
        content.sound = nil
        switch announcement {
        case .phaseEnd(.focus, let autoStarts):
            content.title = "Focus complete"
            content.body = autoStarts ? "Your break has started." : "Take a break?"
            content.categoryIdentifier = autoStarts ? "" : Category.focusEnd
        case .phaseEnd(_, let autoStarts):
            content.title = "Break's over"
            content.body = autoStarts ? "Your next focus has started." : "Ready to focus?"
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

    static func request(_ announcement: Announcement, slot: Int, trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        UNNotificationRequest(identifier: identifiers[slot], content: content(for: announcement), trigger: trigger)
    }

    private static func minutes(_ interval: TimeInterval) -> Int {
        max(1, Int((interval / 60).rounded()))
    }

    // MARK: - Internals

    private var nextSlot: Int { deliveredSlot.map { 1 - $0 } ?? 0 }

    /// Waiting on the user after a phase end, so the delivered prompt is still relevant.
    private func isAwaitingUser(_ engine: TimerEngine) -> Bool {
        engine.phase != .idle && engine.state.endDelivered && !engine.state.nudgesSilenced
    }

    private func plannedAnnouncement(_ engine: TimerEngine, now: Date) -> (Date, Announcement)? {
        guard let boundary = engine.nextBoundary, boundary > now else { return nil }
        switch engine.status {
        case .running:
            let config = engine.configuration
            let autoStarts = engine.phase == .focus ? config.autoStartBreaks : config.autoStartFocus
            return (boundary, .phaseEnd(engine.phase, autoStarts: autoStarts))
        case .overtime:
            guard let end = engine.state.phaseEndDate else { return nil }
            return (boundary, .nudge(engine.phase, overtime: boundary.timeIntervalSince(end)))
        case .paused, .awaitingDecision:
            return nil
        }
    }

    private func currentAnnouncement(_ engine: TimerEngine, events: [TimerEvent]) -> Announcement? {
        switch events.last(where: \.isAnnouncement) {
        case .nudge(let overtime)?: .nudge(engine.phase, overtime: overtime)
        case .focusEnded?, .breakEnded?: .phaseEnd(engine.phase, autoStarts: false)
        default: nil
        }
    }

    private func schedule(_ planned: (Date, Announcement)?, now: Date) {
        guard let planned else {
            cancelPending()
            return
        }
        let (fireDate, announcement) = planned
        let plan = Plan(fireDate: fireDate, announcement: announcement, slot: pending?.slot ?? nextSlot)
        guard plan != pending else { return }
        pending = plan
        add(plan, now: now)
    }

    private func add(_ plan: Plan, now: Date) {
        // The trigger needs a positive interval; a boundary this close is also reconciled in-app.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, plan.fireDate.timeIntervalSince(now)), repeats: false)
        center.add(Self.request(plan.announcement, slot: plan.slot, trigger: trigger))
    }

    private func cancelPending() {
        guard let plan = pending else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifiers[plan.slot]])
        pending = nil
    }

    private func markDelivered(slot: Int) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifiers[1 - slot]])
        deliveredSlot = slot
    }

    private func requestAuthorizationIfNeeded() {
        guard authorization == .notRequested else { return }
        authorization = .requesting
        center.requestAuthorization(options: Self.authorizationOptions) { [weak self] granted in
            guard let self else { return }
            authorization = granted ? .granted : .denied
            // A request added before the first grant is dropped, so send it again.
            if granted, let plan = pending, plan.fireDate > clock.now { add(plan, now: clock.now) }
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
