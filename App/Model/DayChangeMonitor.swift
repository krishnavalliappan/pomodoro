import AppKit

/// Reports the moments "today" may have moved: midnight, wake from sleep, and a clock or
/// time-zone change. Midnight alone isn't enough, since a Mac asleep through it gets no timer.
@MainActor
final class DayChangeMonitor {
    enum Reason: Equatable {
        case dayChanged
        case woke
        case clockChanged
        case timeZoneChanged
    }

    static var workspaceCenter: NotificationCenter { NSWorkspace.shared.notificationCenter }

    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

    init(
        center: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = DayChangeMonitor.workspaceCenter,
        handler: @escaping @MainActor @Sendable (Reason) -> Void
    ) {
        let sources: [(NotificationCenter, Notification.Name, Reason)] = [
            (center, .NSCalendarDayChanged, .dayChanged),
            (center, .NSSystemClockDidChange, .clockChanged),
            (center, .NSSystemTimeZoneDidChange, .timeZoneChanged),
            (workspaceCenter, NSWorkspace.didWakeNotification, .woke),
        ]
        for (center, name, reason) in sources {
            // The day-change and time-zone notifications post on a background thread.
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(reason) }
            }
            tokens.append((center, token))
        }
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens = []
    }
}
