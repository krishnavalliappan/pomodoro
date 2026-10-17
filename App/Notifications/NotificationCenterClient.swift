import Foundation
import UserNotifications
import os

/// The action a user picked on a delivered notification, reduced to plain values so it can
/// cross from the delegate's queue to the main actor.
struct NotificationResponse: Sendable, Equatable {
    var actionIdentifier: String
    var categoryIdentifier: String
}

/// The slice of `UNUserNotificationCenter` the app uses, so tests can substitute a fake.
@MainActor
protocol NotificationCenterClient: AnyObject {
    var onResponse: (@MainActor (NotificationResponse) -> Void)? { get set }
    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
final class LiveNotificationCenter: NSObject, NotificationCenterClient, UNUserNotificationCenterDelegate {
    private nonisolated static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "notifications")

    var onResponse: (@MainActor (NotificationResponse) -> Void)?
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

    func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error {
                Self.log.error("add failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let value = NotificationResponse(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier
        )
        Task { @MainActor in self.onResponse?(value) }
        completionHandler()
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
