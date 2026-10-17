import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class StatsSnapshotTests: XCTestCase {
    /// A week with uneven days, a six-day streak (best twelve), and tasks over and under estimate.
    func testStatsSeeded() throws {
        let h = try ModelHarness()
        try h.seedStats()
        Snapshot.assertLightAndDark(
            StatsView(model: h.makeModel()),
            size: PlannerView.size,
            name: "StatsView",
            variant: "seeded",
            inWindow: true
        )
    }

    func testStatsEmpty() throws {
        let h = try ModelHarness()
        h.setFirstWeekday(2)
        Snapshot.assertLightAndDark(
            StatsView(model: h.makeModel()),
            size: PlannerView.size,
            name: "StatsView",
            variant: "empty",
            inWindow: true
        )
    }

    /// The whole window on its Stats tab, with the Plan | Stats switch.
    func testPlannerWindowStatsTab() throws {
        let h = try ModelHarness()
        try h.seedStats()
        Snapshot.assertLightAndDark(
            PlannerWindow(model: h.makeModel(), tab: .stats),
            size: PlannerWindow.size,
            name: "PlannerWindow",
            variant: "stats",
            inWindow: true
        )
    }

    /// The popover's Today line at the popover's content width, from empty to past the dot limit,
    /// where it falls back to shorter forms instead of wrapping.
    func testTodayRowGallery() {
        let day = CivilDay(year: 2026, month: 10, day: 17)
        let summaries = [
            TodaySummary(day: day),
            TodaySummary(day: day, streak: Streak(current: 6, best: 6)),
            TodaySummary(day: day, focusedSeconds: 100 * 60, completedPomodoros: 4, streak: Streak(current: 6, best: 9)),
            TodaySummary(day: day, focusedSeconds: 50 * 60, completedPomodoros: 2, streak: Streak(current: 1, best: 9)),
            TodaySummary(day: day, focusedSeconds: 245 * 60, completedPomodoros: 9, streak: Streak(current: 23, best: 23)),
            TodaySummary(day: day, focusedSeconds: 380 * 60, completedPomodoros: 14, streak: Streak(current: 120, best: 120)),
        ]
        let gallery = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(summaries.enumerated()), id: \.offset) { entry in
                TodayRow(summary: entry.element, cycle: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: PopoverView.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        Snapshot.assertLightAndDark(
            gallery,
            size: CGSize(width: PopoverView.width, height: 184),
            name: "TodayRow",
            variant: "gallery"
        )
    }
}

extension ModelHarness {
    func setFirstWeekday(_ weekday: Int?) {
        var settings = settingsStore.load()
        settings.firstWeekday = weekday
        try? settingsStore.save(settings)
    }

    /// Weeks starting Monday. This one (12–18 October, today Saturday the 17th) has a session
    /// every day so far, unevenly; the one before has six days, then a gap on Sunday the 11th;
    /// and September holds a twelve-day best streak.
    func seedStats() throws {
        setFirstWeekday(2)
        let created = Self.start - 30 * 86_400
        let spec = try database.tasks.create(title: "Write spec for quick-add", estimatePomodoros: 6, createdAt: created)
        let review = try database.tasks.create(title: "Review PR #42", estimatePomodoros: 4, createdAt: created)
        let docs = try database.tasks.create(title: "Read the design doc", estimatePomodoros: 4, createdAt: created)
        let inbox = try database.tasks.create(title: "Inbox zero", estimatePomodoros: 1, createdAt: created)
        let email = try database.tasks.create(title: "Reply to the hiring email thread", createdAt: created)

        func log(_ month: Int, _ day: Int, _ entries: [(TaskItem?, Double, Bool)]) throws {
            let midnight = Self.utc.date(from: DateComponents(year: 2026, month: month, day: day))!
            for (index, (task, minutes, completed)) in entries.enumerated() {
                let begin = midnight + TimeInterval(6 + index) * 3600
                try database.sessions.insert(FocusSession(
                    taskID: task?.id, start: begin, end: begin + minutes * 60, plannedSeconds: 1500,
                    activeSeconds: minutes * 60, overtimeSeconds: max(0, minutes - 25) * 60, completed: completed))
            }
        }

        for day in 1...12 { try log(9, day, [(nil, 25, true), (nil, 25, true)]) }
        for day in 5...10 { try log(10, day, [(nil, 25, true), (spec, 25, true)]) }

        try log(10, 12, [(spec, 25, true), (spec, 25, true), (review, 25, true), (nil, 50, true)])
        try log(10, 13, [(review, 25, true), (review, 25, true), (email, 15, false)])
        try log(10, 14, [(spec, 50, true), (spec, 50, true), (docs, 25, true), (docs, 25, true)])
        try log(10, 15, [(inbox, 25, true)])
        try log(10, 16, [(spec, 25, true), (spec, 25, true), (spec, 25, true), (review, 40, true)])
        // Today, before the harness's 09:00.
        try log(10, 17, [(docs, 25, true), (spec, 25, true)])
    }
}
