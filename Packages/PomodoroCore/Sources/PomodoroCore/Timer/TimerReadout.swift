import Foundation

/// What a timer readout shows for a snapshot: whole seconds counting down, or up once in overtime.
public struct TimerReadout: Equatable, Sendable {
    public var seconds: Int
    public var isOvertime: Bool

    public init(seconds: Int, isOvertime: Bool = false) {
        self.seconds = max(0, seconds)
        self.isOvertime = isOvertime
    }

    /// Remaining time rounds up, so a fresh 25-minute focus reads 25:00 and 00:00 means done.
    public init(_ snapshot: TimerSnapshot) {
        if Self.isOvertime(snapshot) {
            self.init(seconds: Int(Self.overtime(snapshot).rounded(.down)), isOvertime: true)
        } else {
            self.init(seconds: Int(snapshot.remaining.rounded(.up)))
        }
    }

    /// "18:42", "1:05:00", or "+02:15" in overtime.
    public var text: String {
        (isOvertime ? "+" : "") + Self.clock(seconds)
    }

    public static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Seconds until the readout shows a different value, in `(0, 1]`; `nil` while it's frozen.
    /// Lets the UI refresh exactly when a digit flips instead of polling.
    public static func nextChange(after snapshot: TimerSnapshot) -> TimeInterval? {
        guard snapshot.phase != .idle else { return nil }
        switch snapshot.status {
        case .paused, .awaitingDecision:
            return nil
        case .running, .overtime:
            break
        }
        if isOvertime(snapshot) {
            let overtime = Self.overtime(snapshot)
            return overtime.rounded(.down) + 1 - overtime
        }
        let remaining = snapshot.remaining
        return remaining - (remaining.rounded(.up) - 1)
    }

    private static func isOvertime(_ snapshot: TimerSnapshot) -> Bool {
        guard snapshot.phase != .idle else { return false }
        if case .overtime = snapshot.status { return true }
        return snapshot.isOvertime
    }

    private static func overtime(_ snapshot: TimerSnapshot) -> TimeInterval {
        max(0, snapshot.elapsed - snapshot.plannedDuration)
    }
}

extension MenuBarDisplayMode {
    /// Whether the status item shows a readout that changes every second.
    public var showsSeconds: Bool { self != .iconOnly }
}

/// The status item's text. `nil` means show only the icon.
public enum MenuBarTitle {
    public static let taskTitleLimit = 18

    public static func text(for snapshot: TimerSnapshot, mode: MenuBarDisplayMode, taskTitle: String? = nil) -> String? {
        guard mode != .iconOnly, snapshot.phase != .idle else { return nil }
        let readout = TimerReadout(snapshot)
        var title: String
        if snapshot.status == .paused {
            title = "⏸ " + readout.text
        } else if readout.isOvertime {
            title = readout.text
        } else {
            title = (snapshot.phase == .focus ? "🍅 " : "☕ ") + readout.text
        }
        if mode == .timeAndTask, let task = truncated(taskTitle) {
            title += " · " + task
        }
        return title
    }

    static func truncated(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count > taskTitleLimit else { return trimmed }
        return String(trimmed.prefix(taskTitleLimit - 1)) + "…"
    }
}
