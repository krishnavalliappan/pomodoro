import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class PlannerSnapshotTests: XCTestCase {
    /// The sidebar on its own, with one row selected so its inline editor shows.
    func testTaskListSidebar() throws {
        let h = try ModelHarness()
        let seeded = try h.seedTasks()
        let model = h.makeModel()
        model.selectTask(seeded.reviewPR.id)
        Snapshot.assertLightAndDark(
            TaskListView(model: model, selection: seeded.writeSpec.id, defaults: PopoverViewSnapshotTests.freshDefaults()),
            size: CGSize(width: PlannerView.sidebarWidth, height: 680),
            name: "TaskListView",
            variant: "seeded",
            inWindow: true
        )
    }

    func testTaskListEmpty() throws {
        let h = try ModelHarness()
        Snapshot.assertLightAndDark(
            TaskListView(model: h.makeModel(), defaults: PopoverViewSnapshotTests.freshDefaults()),
            size: CGSize(width: PlannerView.sidebarWidth, height: 320),
            name: "TaskListView",
            variant: "empty",
            inWindow: true
        )
    }

    /// Long titles truncate in the row, ahead of the tag and dots.
    func testTaskListLongTitle() throws {
        let h = try ModelHarness()
        try h.seedLongTitle()
        Snapshot.assertLightAndDark(
            TaskListView(model: h.makeModel(), defaults: PopoverViewSnapshotTests.freshDefaults()),
            size: CGSize(width: PlannerView.sidebarWidth, height: 200),
            name: "TaskListView",
            variant: "longTitle",
            inWindow: true
        )
    }

    func testPlannerWindow() throws {
        let h = try ModelHarness()
        try h.seedTasks()
        Snapshot.assertLightAndDark(
            PlannerView(model: h.makeModel()),
            size: PlannerView.size,
            name: "PlannerView",
            variant: "seeded",
            inWindow: true
        )
    }
}
