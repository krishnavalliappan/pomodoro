import Foundation
import PomodoroCore

/// The floating card's actions beyond the timer's own.
extension AppModel {
    var isMuted: Bool { settings.isMuted }

    func toggleMute() {
        updateSettings { $0.isMuted.toggle() }
    }

    func setShowsFloatingTimer(_ shows: Bool) {
        updateSettings { $0.showsFloatingTimer = shows }
    }

    /// The task the focus counts toward, while it's still open.
    var openCurrentTask: TaskItem? {
        guard let task = tasks.task(id: selectedTaskID), !task.isDone else { return nil }
        return task
    }

    /// Checks off the current task. The focus keeps counting toward it, so its time isn't lost.
    func completeCurrentTask() {
        guard let task = openCurrentTask else { return }
        tasks.setDone(task.id, true)
    }
}
