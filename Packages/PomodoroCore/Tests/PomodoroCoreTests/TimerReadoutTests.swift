import Foundation
import Testing
@testable import PomodoroCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func snapshot(
    _ phase: TimerPhase = .focus,
    _ status: TimerStatus = .running,
    planned: TimeInterval = 25 * 60,
    elapsed: TimeInterval
) -> TimerSnapshot {
    let over = max(0, elapsed - planned)
    return TimerSnapshot(
        phase: phase, status: status, taskID: nil, plannedDuration: planned, elapsed: elapsed,
        remaining: max(0, planned - elapsed), overtime: over > 0.001 ? over : 0, completedFocusesInCycle: 0
    )
}

private let idle = TimerSnapshot(
    phase: .idle, status: .awaitingDecision, taskID: nil, plannedDuration: 0, elapsed: 0, remaining: 0,
    overtime: 0, completedFocusesInCycle: 0
)

struct TimerReadoutTests {
    @Test func clockFormatting() {
        #expect(TimerReadout.clock(0) == "00:00")
        #expect(TimerReadout.clock(59) == "00:59")
        #expect(TimerReadout.clock(18 * 60 + 42) == "18:42")
        #expect(TimerReadout.clock(3600) == "1:00:00")
        #expect(TimerReadout.clock(2 * 3600 + 5 * 60 + 9) == "2:05:09")
        #expect(TimerReadout.clock(-5) == "00:00")
    }

    @Test func remainingRoundsUp() {
        #expect(TimerReadout(snapshot(elapsed: 0)).text == "25:00")
        #expect(TimerReadout(snapshot(elapsed: 0.4)).text == "25:00")
        #expect(TimerReadout(snapshot(elapsed: 1)).text == "24:59")
        #expect(TimerReadout(snapshot(elapsed: 6 * 60 + 18)).text == "18:42")
        #expect(TimerReadout(snapshot(elapsed: 25 * 60)).text == "00:00")
    }

    @Test func overtimeCountsUpWithPlus() {
        let readout = TimerReadout(snapshot(.focus, .overtime(since: t0), elapsed: 25 * 60 + 135.7))
        #expect(readout == TimerReadout(seconds: 135, isOvertime: true))
        #expect(readout.text == "+02:15")
        #expect(TimerReadout(snapshot(.focus, .overtime(since: t0), elapsed: 25 * 60)).text == "+00:00")
    }

    @Test func pausedInOvertimeStillReadsAsOvertime() {
        #expect(TimerReadout(snapshot(.focus, .paused, elapsed: 25 * 60 + 30)).text == "+00:30")
    }

    @Test func idleReadsZero() {
        #expect(TimerReadout(idle).text == "00:00")
    }

    @Test func nextChangeLandsOnTheNextDigitFlip() throws {
        #expect(TimerReadout.nextChange(after: snapshot(elapsed: 0)) == 1)
        let mid = try #require(TimerReadout.nextChange(after: snapshot(elapsed: 10.25)))
        #expect(abs(mid - 0.75) < 1e-9)
        let over = try #require(TimerReadout.nextChange(after: snapshot(.focus, .overtime(since: t0), elapsed: 25 * 60 + 2.6)))
        #expect(abs(over - 0.4) < 1e-9)
    }

    @Test func nextChangeIsAlwaysWithinOneSecond() throws {
        for elapsed in stride(from: 0.0, through: 1600, by: 0.37) {
            let status: TimerStatus = elapsed > 1500 ? .overtime(since: t0) : .running
            let delay = try #require(TimerReadout.nextChange(after: snapshot(.focus, status, elapsed: elapsed)))
            #expect(delay > 0 && delay <= 1, "elapsed \(elapsed)")
        }
    }

    @Test func frozenReadoutsNeverChange() {
        #expect(TimerReadout.nextChange(after: idle) == nil)
        #expect(TimerReadout.nextChange(after: snapshot(.focus, .paused, elapsed: 30)) == nil)
        #expect(TimerReadout.nextChange(after: snapshot(.shortBreak, .awaitingDecision, planned: 300, elapsed: 300)) == nil)
    }
}

struct MenuBarTitleTests {
    @Test func iconOnlyNeverHasATitle() {
        #expect(MenuBarTitle.text(for: snapshot(elapsed: 60), mode: .iconOnly) == nil)
        #expect(MenuBarTitle.text(for: snapshot(.focus, .overtime(since: t0), elapsed: 1600), mode: .iconOnly) == nil)
        #expect(MenuBarTitle.text(for: idle, mode: .iconOnly) == nil)
    }

    @Test func idleShowsOnlyTheIconInEveryMode() {
        for mode in MenuBarDisplayMode.allCases {
            #expect(MenuBarTitle.text(for: idle, mode: mode, taskTitle: "Write spec") == nil)
        }
    }

    @Test func timeMode() {
        #expect(MenuBarTitle.text(for: snapshot(elapsed: 6 * 60 + 18), mode: .time) == "🍅 18:42")
        #expect(MenuBarTitle.text(for: snapshot(.shortBreak, planned: 300, elapsed: 110), mode: .time) == "☕ 03:10")
        #expect(MenuBarTitle.text(for: snapshot(.longBreak, planned: 900, elapsed: 0), mode: .time) == "☕ 15:00")
        #expect(MenuBarTitle.text(for: snapshot(.focus, .overtime(since: t0), elapsed: 25 * 60 + 135), mode: .time) == "+02:15")
        #expect(MenuBarTitle.text(for: snapshot(.shortBreak, .overtime(since: t0), planned: 300, elapsed: 340), mode: .time) == "+00:40")
        #expect(MenuBarTitle.text(for: snapshot(.focus, .paused, elapsed: 6 * 60 + 18), mode: .time) == "⏸ 18:42")
        #expect(MenuBarTitle.text(for: snapshot(.focus, .paused, elapsed: 25 * 60 + 5), mode: .time) == "⏸ +00:05")
        #expect(MenuBarTitle.text(for: snapshot(elapsed: 0), mode: .time, taskTitle: "Write spec") == "🍅 25:00")
    }

    @Test func timeAndTaskMode() {
        let running = snapshot(elapsed: 6 * 60 + 18)
        #expect(MenuBarTitle.text(for: running, mode: .timeAndTask, taskTitle: "Write spec") == "🍅 18:42 · Write spec")
        #expect(MenuBarTitle.text(for: running, mode: .timeAndTask, taskTitle: nil) == "🍅 18:42")
        #expect(MenuBarTitle.text(for: running, mode: .timeAndTask, taskTitle: "   ") == "🍅 18:42")
        #expect(
            MenuBarTitle.text(for: running, mode: .timeAndTask, taskTitle: "Refactor the planner timeline")
                == "🍅 18:42 · Refactor the plan…"
        )
        #expect(MenuBarTitle.text(for: snapshot(.focus, .overtime(since: t0), elapsed: 1635), mode: .timeAndTask, taskTitle: "Spec") == "+02:15 · Spec")
    }

    @Test func truncationKeepsTheLimit() throws {
        let exact = String(repeating: "a", count: MenuBarTitle.taskTitleLimit)
        #expect(MenuBarTitle.truncated(exact) == exact)
        let long = try #require(MenuBarTitle.truncated(exact + "b"))
        #expect(long.count == MenuBarTitle.taskTitleLimit)
        #expect(long.hasSuffix("…"))
    }

    @Test func onlyIconOnlyAvoidsPerSecondUpdates() {
        #expect(!MenuBarDisplayMode.iconOnly.showsSeconds)
        #expect(MenuBarDisplayMode.time.showsSeconds)
        #expect(MenuBarDisplayMode.timeAndTask.showsSeconds)
    }
}
