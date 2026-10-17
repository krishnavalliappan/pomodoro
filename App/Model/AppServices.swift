import Foundation

/// The model and the services that mirror it, kept alive together for the app's lifetime.
///
/// Only the model's update hook holds the services strongly; they reach the model weakly
/// (`commands`, the `SystemEvents` closure), so there is no cycle.
@MainActor
final class AppServices {
    let model: AppModel
    let notifications: NotificationService
    let appNap: AppNapGuard
    let systemEvents: SystemEvents

    init(
        notifications: NotificationService,
        appNap: AppNapGuard,
        makeModel: (@escaping AppModel.EngineUpdate) -> AppModel,
        makeSystemEvents: (@escaping @MainActor () -> Void) -> SystemEvents
    ) {
        self.notifications = notifications
        self.appNap = appNap
        // Passed at creation so the launch reconcile of a restored session gets the first sync.
        let model = makeModel { engine, events in
            notifications.sync(with: engine, events: events)
            appNap.update(with: engine)
        }
        // That first sync releases responses held from a cold launch, but they resume on a later
        // main-actor turn, after this.
        notifications.commands = model
        self.model = model
        systemEvents = makeSystemEvents { [weak model] in model?.reconcile() }
    }

    static func live() -> AppServices {
        AppServices(
            notifications: NotificationService(center: LiveNotificationCenter()),
            appNap: AppNapGuard(),
            makeModel: { AppModel.live(onEngineUpdate: $0) },
            makeSystemEvents: { SystemEvents(reconcile: $0) }
        )
    }
}

extension AppModel: TimerCommandHandling {}
