import AppKit
import Foundation

/// Calls `reconcile` whenever the timer may have missed a boundary: after the Mac or its screens
/// wake, around screen lock and fast user switching, and when the system clock is changed
/// (`TimerEngine` needs a reconcile after a clock jump to keep its stored dates consistent).
@MainActor
final class SystemEvents {
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    static let workspaceNames: [Notification.Name] = [
        NSWorkspace.didWakeNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
        NSWorkspace.sessionDidResignActiveNotification,
    ]
    static let distributedNames: [Notification.Name] = [screenLocked, screenUnlocked]
    static let localNames: [Notification.Name] = [.NSSystemClockDidChange]

    private let reconcile: @MainActor () -> Void
    private var observers: ObserverBag?

    /// The centers are injectable so tests can post on private instances.
    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        localCenter: NotificationCenter = .default,
        reconcile: @escaping @MainActor () -> Void
    ) {
        self.reconcile = reconcile
        let bag = ObserverBag()
        for (center, names) in [(workspaceCenter, Self.workspaceNames), (distributedCenter, Self.distributedNames), (localCenter, Self.localNames)] {
            for name in names {
                bag.observe(name, on: center) { [weak self] in self?.reconcile() }
            }
        }
        observers = bag
    }
}

/// Removes its observers when released, since a `@MainActor` deinit can't reach isolated state
/// on macOS 14.
private final class ObserverBag: @unchecked Sendable {
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

    func observe(_ name: Notification.Name, on center: NotificationCenter, action: @escaping @MainActor @Sendable () -> Void) {
        // No queue, so a notification posted on the main thread is handled before `post` returns.
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { action() }
            } else {
                Task { @MainActor in action() }
            }
        }
        tokens.append((center, token))
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
