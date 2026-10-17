import Foundation

@MainActor
protocol ScheduledTimer: AnyObject {
    func cancel()
}

/// One-shot wall-clock timers, injectable so tests can see exactly what is scheduled.
@MainActor
protocol TimerScheduling: AnyObject {
    func schedule(at date: Date, _ action: @escaping @MainActor @Sendable () -> Void) -> any ScheduledTimer
}

@MainActor
final class RunLoopScheduler: TimerScheduling {
    /// Small enough that the readout flips on time, large enough for the system to coalesce wakeups.
    static let tolerance: TimeInterval = 0.05

    func schedule(at date: Date, _ action: @escaping @MainActor @Sendable () -> Void) -> any ScheduledTimer {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = Self.tolerance
        // Common modes keep it firing while a menu or the popover is tracking events.
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopTimer(timer)
    }
}

@MainActor
private final class RunLoopTimer: ScheduledTimer {
    private let timer: Timer

    init(_ timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}
