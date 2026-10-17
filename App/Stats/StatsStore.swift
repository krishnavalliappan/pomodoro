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

    private(set) var week: StatsWeek
    /// Briefly the previous week's after navigating, until the observation delivers.
    private(set) var report: WeekReport

    @ObservationIgnored let model: AppModel
    @ObservationIgnored private var generation = 0

    init(model: AppModel) {
        self.model = model
        let stats = Stats(calendar: model.database.calendar, firstWeekday: model.settings.firstWeekday)
        let week = stats.week(containing: model.clock.now)
        self.week = week
        report = WeekReport(week: week, today: stats.day(containing: model.clock.now), days: week.days.map { DayFocus(day: $0) })
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

    var today: CivilDay { stats.day(containing: model.clock.now) }
    var isCurrentWeek: Bool { week.contains(today) }
    var isStale: Bool { report.week != week }

    func showPreviousWeek() {
        week = week.previous
    }

    func showNextWeek() {
        guard !isCurrentWeek else { return }
        week = week.next
    }

    func showCurrentWeek() {
        let current = stats.week(containing: model.clock.now)
        if current != week { week = current }
    }

    /// After the first weekday changes: the same week, starting on the new day.
    func realign() {
        let anchor = isCurrentWeek ? today : week.start.adding(days: 3)
        let aligned = stats.week(containing: anchor)
        if aligned != week { week = aligned }
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
