import Foundation
import Observation
import PomodoroCore
import os

/// The week the Stats view shows, kept live by one observation of that week only.
///
/// The report is built in a single read on GRDB's queue, so navigating weeks never blocks the
/// main thread; nothing here follows the timer's 1 Hz tick.
@MainActor
@Observable
final class StatsStore {
    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "stats")

    /// A day in the week on show. The week itself is derived from it with the current first
    /// weekday, so a settings change realigns it even while the Stats tab isn't mounted.
    private var anchor: CivilDay
    /// Briefly the previous week's after navigating, until the observation delivers.
    private(set) var report: WeekReport

    @ObservationIgnored let model: AppModel
    @ObservationIgnored private var generation = 0

    init(model: AppModel) {
        self.model = model
        let stats = Stats(calendar: model.database.calendar, firstWeekday: model.settings.firstWeekday)
        let today = stats.day(containing: model.clock.now)
        let week = stats.week(containing: today)
        anchor = today
        report = WeekReport(week: week, today: today, days: week.days.map { DayFocus(day: $0) })
        // Synchronous once, so the first frame already has its numbers.
        do {
            report = try model.database.stats.weekReport(week, stats: stats, now: model.clock.now)
        } catch {
            Self.log.error("reading stats failed: \(String(describing: error), privacy: .public)")
        }
    }

    var stats: Stats {
        Stats(calendar: model.database.calendar, firstWeekday: model.settings.firstWeekday)
    }

    var week: StatsWeek { stats.week(containing: anchor) }
    var today: CivilDay { stats.day(containing: model.clock.now) }
    var isCurrentWeek: Bool { week.contains(today) }
    var isStale: Bool { report.week != week }

    func showPreviousWeek() {
        anchor = anchor.adding(days: -7)
    }

    func showNextWeek() {
        guard !isCurrentWeek else { return }
        anchor = anchor.adding(days: 7)
    }

    func showCurrentWeek() {
        if anchor != today { anchor = today }
    }

    /// Runs for as long as the view shows; the view restarts it when the week or day changes.
    func observe() async {
        generation += 1
        let generation = generation
        for await value in model.database.stats.observeWeekReport(week, stats: stats, now: model.clock.now) {
            guard self.generation == generation, !Task.isCancelled else { return }
            if value != report { report = value }
        }
    }
}
