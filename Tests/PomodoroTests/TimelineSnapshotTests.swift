import PomodoroCore
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class TimelineSnapshotTests: XCTestCase {
    /// The planner's detail pane at the window's default size.
    static let size = CGSize(width: PlannerView.size.width - PlannerView.sidebarWidth, height: 640)

    private let day = ModelHarness.utc.startOfDay(for: ModelHarness.start)

    /// The seeded tasks' day at 09:00, plus blocks that overlap three ways (Review PR, Write
    /// spec, Standup), chain (Lunch, Email, Walk), and use palette colours. Review PR is running.
    private func seededDay() throws -> (ModelHarness, AppModel) {
        let h = try ModelHarness()
        let seeded = try h.seedTasks()
        func add(_ title: String, _ hour: Double, minutes: Double, task: TaskItem? = nil, color: String? = nil) throws {
            try h.database.blocks.insert(TimeBlock(
                taskID: task?.id, title: title, start: day + hour * 3600, duration: minutes * 60, color: color))
        }
        try add(seeded.writeSpec.title, 9, minutes: 90, task: seeded.writeSpec)
        try add("Standup", 9.5, minutes: 15, color: "teal")
        try add("Lunch", 12, minutes: 60, color: "green")
        try add("Email", 12.75, minutes: 30, color: "orange")
        try add("Walk", 13, minutes: 30, color: "green")
        try add("Design review", 15, minutes: 45, color: "purple")
        try add("Read the design doc", 16, minutes: 100, task: seeded.all.first { $0.title == "Read the design doc" })
        let model = h.makeModel()
        model.startFocus(on: seeded.reviewPR.id)
        return (h, model)
    }

    func testSeededDay() throws {
        let (_, model) = try seededDay()
        assertTimeline(TimelineStore(model: model), "seeded")
    }

    func testEmptyDay() throws {
        let h = try ModelHarness()
        assertTimeline(TimelineStore(model: h.makeModel()), "empty")
    }

    /// Another day: no now line, and the Today button is enabled.
    func testOtherDay() throws {
        let (_, model) = try seededDay()
        let store = TimelineStore(model: model)
        store.showNextDay()
        assertTimeline(store, "otherDay")
    }

    /// A block mid-creation, with its title field and task picker.
    func testNewBlockEditor() throws {
        let (_, model) = try seededDay()
        let store = TimelineStore(model: model)
        let start = day + 10.75 * 3600
        store.dragCreate(from: start, to: start + 3600)
        store.endDrag()
        store.editorTitle = "Deep work"
        store.selectedBlockID = nil
        assertTimeline(store, "editor")
    }

    private func assertTimeline(_ store: TimelineStore, _ variant: String, file: StaticString = #filePath, line: UInt = #line) {
        Snapshot.assertLightAndDark(
            DayTimelineView(store: store),
            size: Self.size,
            name: "DayTimelineView",
            variant: variant,
            inWindow: true,
            file: file,
            line: line
        )
    }
}
