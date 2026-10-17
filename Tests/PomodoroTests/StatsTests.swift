import PomodoroCore
import XCTest
@testable import Pomodoro

@MainActor
final class StatsTests: XCTestCase {
    private let focus: TimeInterval = 25 * 60

    func testTodaySummaryUpdatesAfterASessionIsRecorded() throws {
        let h = try ModelHarness()
        // Yesterday's focus starts a streak that today keeps until it ends.
        let yesterday = ModelHarness.start - 86_400
        try h.database.sessions.insert(FocusSession(
            start: yesterday, end: yesterday + focus, plannedSeconds: focus, activeSeconds: focus, completed: true))
        let model = h.makeModel()
        XCTAssertEqual(model.today, TodaySummary(day: CivilDay(year: 2026, month: 10, day: 17), streak: Streak(current: 1, best: 1)))
        XCTAssertEqual(TodayRow.text(model.today), "No focus yet · 🔥 1-day streak")

        model.startFocus()
        h.scheduler.advance(by: focus + 60)
        model.startBreak()

        XCTAssertEqual(model.today.completedPomodoros, 1)
        XCTAssertEqual(model.today.focusedSeconds, focus + 60, accuracy: 0.001)
        XCTAssertEqual(model.today.streak, Streak(current: 2, best: 2))
        XCTAssertEqual(model.completedToday, 1)
        XCTAssertEqual(TodayRow.text(model.today), "26m · 1 🍅 · 🔥 2-day streak")
    }

    func testStoppedFocusAddsTimeButNoPomodoro() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.startFocus()
        h.scheduler.advance(by: 10 * 60)
        model.stopAndLog()
        XCTAssertEqual(model.today.completedPomodoros, 0)
        XCTAssertEqual(model.today.focusedSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(model.today.streak, .zero)
        XCTAssertEqual(TodayRow.text(model.today), "10m · 0 🍅")
    }

    func testTodayRowText() {
        let day = CivilDay(year: 2026, month: 10, day: 17)
        let summary = TodaySummary(day: day, focusedSeconds: 100 * 60, completedPomodoros: 4, streak: Streak(current: 6, best: 9))
        XCTAssertEqual(TodayRow.text(summary), "1h 40m · 4 🍅 · 🔥 6-day streak")
        XCTAssertEqual(TodayRow.text(summary, isLong: false), "1h 40m · 4 🍅 · 🔥 6")
        XCTAssertEqual(TodayRow.text(TodaySummary(day: day)), "No focus yet")
        XCTAssertEqual(TodayRow.text(TodaySummary(day: day), isLong: false), "0m")
        XCTAssertEqual(TodayRow.accessibilityText(summary), "Today: 1h 40m of focus, 4 pomodoros, 6-day streak")
    }

    // MARK: - Stats store

    func testStatsStoreNavigatesWeeksButNotPastThisOne() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.updateSettings { $0.firstWeekday = 2 }
        let store = StatsStore(model: model)
        let thisWeek = StatsWeek(start: CivilDay(year: 2026, month: 10, day: 12))
        XCTAssertEqual(store.week, thisWeek)
        XCTAssertTrue(store.isCurrentWeek)

        store.showNextWeek()
        XCTAssertEqual(store.week, thisWeek, "the future has no stats")
        store.showPreviousWeek()
        store.showPreviousWeek()
        XCTAssertEqual(store.week, thisWeek.previous.previous)
        XCTAssertFalse(store.isCurrentWeek)
        store.showNextWeek()
        XCTAssertEqual(store.week, thisWeek.previous)
        store.showCurrentWeek()
        XCTAssertEqual(store.week, thisWeek)
    }

    func testStatsStoreRealignsToANewFirstWeekday() throws {
        let h = try ModelHarness()
        let model = h.makeModel()
        model.updateSettings { $0.firstWeekday = 2 }
        let store = StatsStore(model: model)
        model.updateSettings { $0.firstWeekday = 7 }
        store.realign()
        XCTAssertEqual(store.week.start, CivilDay(year: 2026, month: 10, day: 17))
        XCTAssertTrue(store.isCurrentWeek)
    }

    func testStatsStoreLoadsAtOnceAndFollowsNewSessions() async throws {
        let h = try ModelHarness()
        try h.seedCompletedSessions(2)
        let model = h.makeModel()
        let store = StatsStore(model: model)
        XCTAssertEqual(store.report.totalSeconds, 2 * focus, "loaded before the first frame")

        let observing = Task { await store.observe() }
        defer { observing.cancel() }
        model.startFocus()
        h.scheduler.advance(by: focus)
        model.startBreak()
        try await waitUntil { store.report.totalSeconds == 3 * self.focus }
        XCTAssertEqual(store.report.completedPomodoros, 3)
    }

    func testStatsStoreObservesTheWeekItShows() async throws {
        let h = try ModelHarness()
        let lastWeek = ModelHarness.start - 7 * 86_400
        try h.database.sessions.insert(FocusSession(
            start: lastWeek, end: lastWeek + focus, plannedSeconds: focus, activeSeconds: focus, completed: true))
        let store = StatsStore(model: h.makeModel())
        XCTAssertEqual(store.report.totalSeconds, 0)
        XCTAssertEqual(store.report.previousWeekSeconds, focus)

        store.showPreviousWeek()
        XCTAssertTrue(store.isStale)
        let observing = Task { await store.observe() }
        defer { observing.cancel() }
        try await waitUntil { !store.isStale }
        XCTAssertEqual(store.report.totalSeconds, focus)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date() + timeout
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("condition not met within \(timeout)s", file: file, line: line)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
