import Foundation
import UserNotifications
import os

/// The action a user picked on a delivered notification, reduced to plain values so it can
/// cross from the delegate's queue to the main actor.
struct NotificationResponse: Sendable, Equatable {
    /// `userInfo` key holding the start of the phase a notification is about, so an action on an
    /// old banner can't act on a later session of the same phase.
    static let phaseIDKey = "phaseID"

    var actionIdentifier: String
    var categoryIdentifier: String
    var phaseID: TimeInterval?

    init(actionIdentifier: String, categoryIdentifier: String, phaseID: TimeInterval? = nil) {
        self.actionIdentifier = actionIdentifier
        self.categoryIdentifier = categoryIdentifier
        self.phaseID = phaseID
    }

    init(actionIdentifier: String, content: UNNotificationContent) {
        self.init(
            actionIdentifier: actionIdentifier,
            categoryIdentifier: content.categoryIdentifier,
            phaseID: content.userInfo[Self.phaseIDKey] as? TimeInterval
        )
    }
}

/// The slice of `UNUserNotificationCenter` the app uses, so tests can substitute a fake.
@MainActor
protocol NotificationCenterClient: AnyObject {
    /// Returns once the response has been handled; the system is told it's complete only then.
    var onResponse: (@MainActor (NotificationResponse) async -> Void)? { get set }
    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    /// Whether the system accepted the request. It refuses them until notifications are allowed.
    func add(_ request: UNNotificationRequest) async -> Bool
    func pendingRequestIdentifiers() async -> Set<String>
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

/// Becomes the center's delegate on init. Create it before the app finishes launching, or a cold
/// launch from a notification action loses that action.
@MainActor
final class LiveNotificationCenter: NSObject, NotificationCenterClient, UNUserNotificationCenterDelegate {
    private nonisolated static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "notifications")

    var onResponse: (@MainActor (NotificationResponse) async -> Void)?
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: options) { granted, error in
            if let error {
                Self.log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in completion(granted) }
        }
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            center.add(request) { error in
                if let error {
                    Self.log.error("add failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: error == nil)
            }
        }
    }

    func pendingRequestIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// The async form: the system treats the response as handled when this returns, which is
    /// after the main-actor handler has dispatched the timer command.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let value = NotificationResponse(actionIdentifier: response.actionIdentifier, content: response.notification.request.content)
        await receive(value)
    }

    private func receive(_ response: NotificationResponse) async {
        guard let onResponse else {
            Self.log.error("response dropped: no handler installed")
            return
        }
        await onResponse(response)
    }

    /// A menu-bar app counts as frontmost while its popover is open; show banners then too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
