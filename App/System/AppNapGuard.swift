import Foundation
import PomodoroCore

protocol ActivityScheduling {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol
    func endActivity(_ activity: any NSObjectProtocol)
}

extension ProcessInfo: ActivityScheduling {}

/// Opts out of App Nap only while the engine has a boundary coming (a running phase, or overtime
/// with nudges due), and never prevents idle sleep.
///
/// The pre-scheduled notification already shows the banner on time while napping, but App Nap
/// can defer the app's own boundary timer by seconds to minutes, and with it the chime (played
/// in-app, see `NotificationService`) and the menu-bar title flipping to overtime. The activity
/// costs nothing by itself: it only stops the system from coalescing and deferring our timers.
/// Paused, idle and silenced-overtime states release it, so the app naps normally then.
@MainActor
final class AppNapGuard {
    nonisolated static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
    nonisolated static let reason = "Pomodoro timer running"

    private let scheduler: any ActivityScheduling
    private var activity: Activity?

    init(scheduler: any ActivityScheduling = ProcessInfo.processInfo) {
        self.scheduler = scheduler
    }

    var isHolding: Bool { activity != nil }

    func update(with engine: TimerEngine) {
        setHolding(engine.nextBoundary != nil)
    }

    func setHolding(_ holding: Bool) {
        guard holding != isHolding else { return }
        activity = holding ? Activity(scheduler: scheduler) : nil
    }
}

/// Ends the activity when released, so dropping the guard can't leak it.
private final class Activity {
    private let scheduler: any ActivityScheduling
    private let token: any NSObjectProtocol

    init(scheduler: any ActivityScheduling) {
        self.scheduler = scheduler
        token = scheduler.beginActivity(options: AppNapGuard.options, reason: AppNapGuard.reason)
    }

    deinit { scheduler.endActivity(token) }
}
