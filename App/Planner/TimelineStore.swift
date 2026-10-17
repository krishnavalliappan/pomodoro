import Foundation
import Observation
import PomodoroCore
import os

/// The planner timeline's day: its blocks, the drag in progress, and the inline editor.
///
/// Drags only touch `drag`, so the dragged block follows the pointer without a database write;
/// the drop writes once. Writes are synchronous and followed by a synchronous read, so a dropped
/// block shows at once with no optimistic state to reconcile, and the observation is fenced so
/// a value fetched before the write can't put it back.
@MainActor
@Observable
final class TimelineStore {
    private static let log = Logger(subsystem: "dev.krishna.pomodoro", category: "timeline")

    static let hourHeight: Double = 48
    static let fallbackDuration: TimeInterval = 30 * 60

    struct Drag: Equatable {
        enum Kind: Equatable {
            case move
            case resize
            case create
        }

        var kind: Kind
        var original: TimeBlock
        /// Where the block would land if dropped now: snapped and clamped.
        var preview: TimeBlock
    }

    /// The inline title field and task picker, for a new block or a rename.
    struct Editor: Equatable {
        /// A new block's draft, or the row being renamed with the editor's title and task.
        var block: TimeBlock
        var isNew: Bool
        /// The row as the rename began, so a save writes only what the editor changed.
        var base: TimeBlock
    }

    private(set) var day: CivilDay
    private(set) var layout: TimelineLayout
    private(set) var drag: Drag?
    var editor: Editor?
    var selectedBlockID: UUID?

    private var saved: [TimeBlock] = []

    @ObservationIgnored let model: AppModel
    private var clock: any TimeSource { model.clock }
    /// Database writes made, for tests that check a drag writes only on drop.
    @ObservationIgnored private(set) var writeCount = 0
    /// Bumped by each successful write. A subscription that began before it may still deliver
    /// a value fetched before the write, so its values are dropped and it's replaced.
    @ObservationIgnored private(set) var writeGeneration = 0
    @ObservationIgnored private var generation = 0

    init(model: AppModel, day: CivilDay? = nil) {
        self.model = model
        let day = day ?? model.database.day(containing: model.clock.now)
        self.day = day
        layout = Self.layout(for: day, calendar: model.database.calendar)
        // Synchronous once, so the first frame already has its blocks.
        reload()
    }

    private static func layout(for day: CivilDay, calendar: Calendar) -> TimelineLayout {
        TimelineLayout(day: day, calendar: calendar, hourHeight: hourHeight)
    }

    // MARK: - Reading

    var now: Date { clock.now }
    private var database: AppDatabase { model.database }
    var calendar: Calendar { database.calendar }
    var today: CivilDay { database.day(containing: clock.now) }
    var isToday: Bool { day == today }

    /// What's on the timeline: saved blocks, with the drag's preview and a new block's draft.
    var blocks: [TimeBlock] {
        var byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let drag { byID[drag.preview.id] = drag.preview }
        if let editor, editor.isNew { byID[editor.block.id] = editor.block }
        return byID.values.sorted { ($0.start, $0.duration, $0.id.uuidString) < ($1.start, $1.duration, $1.id.uuidString) }
    }

    /// The block being drawn or named that isn't saved yet.
    var draftID: UUID? {
        if let drag, drag.kind == .create { return drag.preview.id }
        if let editor, editor.isNew { return editor.block.id }
        return nil
    }

    /// Where the editor's block is now. A rename follows a move made while it's open.
    var editorBlock: TimeBlock? {
        guard let editor else { return nil }
        guard !editor.isNew, let current = block(id: editor.block.id) else { return editor.block }
        var shown = current
        shown.title = editor.block.title
        shown.taskID = editor.block.taskID
        return shown
    }

    func block(id: UUID?) -> TimeBlock? {
        guard let id else { return nil }
        return blocks.first { $0.id == id }
    }

    /// A block scheduled now for the task the running focus counts toward (or for no task,
    /// during a focus without one). Read from the engine each time rather than remembered, so a
    /// stop, a task switch or the block's end all clear it.
    func isRunning(_ block: TimeBlock) -> Bool {
        // Re-evaluated as now crosses a block's start or end, not just on the minute.
        _ = model.blockBoundaryTick
        return model.isFocusing && block.taskID == model.selectedTaskID && block.contains(now)
    }

    /// Tasks a block can link to: open ones for today and the inbox.
    var linkableTasks: [TaskItem] {
        (model.tasks.overview.today + model.tasks.overview.inbox).filter { !$0.isDone }
    }

    func duration(forTask id: UUID) -> TimeInterval {
        guard let estimate = model.tasks.task(id: id)?.estimatePomodoros, estimate > 0 else { return Self.fallbackDuration }
        return TimeInterval(estimate) * model.settings.defaultProfile.focusDuration
    }

    // MARK: - Days

    func show(_ day: CivilDay) {
        guard day != self.day else { return }
        cancelDrag()
        editor = nil
        selectedBlockID = nil
        self.day = day
        layout = Self.layout(for: day, calendar: calendar)
        saved = []
        reload()
    }

    func showToday() { show(today) }
    func showPreviousDay() { show(day(offsetBy: -1)) }
    func showNextDay() { show(day(offsetBy: 1)) }

    private func day(offsetBy days: Int) -> CivilDay {
        let noon = calendar.date(byAdding: .hour, value: 12, to: day.start(in: calendar)) ?? day.start(in: calendar)
        let moved = calendar.date(byAdding: .day, value: days, to: noon) ?? noon + TimeInterval(days) * 86_400
        return database.day(containing: moved)
    }

    // MARK: - Observation

    /// Follows the visible range until cancelled. The planner runs it in `.task(id: day)`, so it
    /// stops with the window and restarts when the day changes.
    func observe() async {
        generation += 1
        let generation = generation
        model.plannerDidAppear()
        defer { model.plannerDidDisappear() }
        while self.generation == generation, !Task.isCancelled {
            let fence = writeGeneration
            var isStale = false
            for await value in database.blocks.observe(in: layout.visible) {
                guard self.generation == generation, !Task.isCancelled else { return }
                guard receive(value, subscribedAt: fence) else {
                    isStale = true
                    break
                }
            }
            // A fresh subscription fetches after the write, so its first value is current.
            guard isStale else { return }
        }
    }

    /// Takes an observed value, unless its subscription began before the latest write.
    @discardableResult
    func receive(_ value: [TimeBlock], subscribedAt fence: Int) -> Bool {
        guard fence == writeGeneration else { return false }
        apply(value)
        return true
    }

    private func reload() {
        attempt("reading blocks") { apply(try database.blocks.blocks(in: layout.visible)) }
    }

    private func apply(_ value: [TimeBlock]) {
        guard value != saved else { return }
        saved = value
        for id in Set(value.compactMap(\.taskID)) { model.tasks.ensureLoaded(id) }
        if let editor, !editor.isNew, !value.contains(where: { $0.id == editor.block.id }) { self.editor = nil }
        if let id = selectedBlockID, !value.contains(where: { $0.id == id }) { selectedBlockID = nil }
        // The popover suggests the task of the block scheduled now, and when that next changes
        // depends on today's blocks.
        if isToday { model.blocksDidChange() }
    }

    // MARK: - Dragging

    func dragMove(_ id: UUID, by delta: TimeInterval) {
        updateDrag(.move, id) { original in
            var block = original
            block.start = layout.movedStart(original.start, duration: original.duration, by: delta)
            return block
        }
    }

    func dragResize(_ id: UUID, by delta: TimeInterval) {
        updateDrag(.resize, id) { original in
            var block = original
            block.duration = layout.resizedDuration(start: original.start, duration: original.duration, by: delta)
            return block
        }
    }

    /// A drag across empty space, from where it began to where the pointer is.
    func dragCreate(from start: Date, to end: Date) {
        let range = layout.creationRange(from: start, to: end)
        if var current = drag, current.kind == .create {
            current.preview.start = range.lowerBound
            current.preview.duration = range.upperBound.timeIntervalSince(range.lowerBound)
            if current != drag { drag = current }
        } else {
            editor = nil
            let block = TimeBlock(title: "", start: range.lowerBound, duration: range.upperBound.timeIntervalSince(range.lowerBound))
            drag = Drag(kind: .create, original: block, preview: block)
        }
    }

    /// Writes the drag's result once. A new block opens the editor instead, and is written
    /// when it gets a title or a task.
    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        switch drag.kind {
        case .create:
            selectedBlockID = nil
            editor = Editor(block: drag.preview, isNew: true, base: drag.preview)
        case .move, .resize:
            selectedBlockID = drag.preview.id
            guard drag.preview != drag.original else { return }
            let preview = drag.preview
            if drag.kind == .move {
                edit(preview.id, TimeBlockEdit(start: preview.start), "moving a block")
            } else {
                edit(preview.id, TimeBlockEdit(duration: preview.duration), "resizing a block")
            }
        }
    }

    func cancelDrag() {
        if drag != nil { drag = nil }
    }

    private func updateDrag(_ kind: Drag.Kind, _ id: UUID, _ change: (TimeBlock) -> TimeBlock) {
        let original: TimeBlock
        if let drag, drag.kind == kind, drag.original.id == id {
            original = drag.original
        } else if let block = block(id: id) {
            original = block
        } else {
            return
        }
        let next = Drag(kind: kind, original: original, preview: change(original))
        if next != drag { drag = next }
    }

    // MARK: - Dropping tasks

    /// A task dropped with the block's top at `date`, sized by its estimate.
    @discardableResult
    func dropTask(_ id: UUID, at date: Date) -> TimeBlock? {
        model.tasks.ensureLoaded(id)
        guard let task = model.tasks.task(id: id) else { return nil }
        let duration = min(duration(forTask: id), layout.visibleDuration)
        let block = TimeBlock(
            taskID: task.id, title: task.title, start: layout.droppedStart(at: date, duration: duration), duration: duration
        )
        guard insert(block) else { return nil }
        selectedBlockID = block.id
        return block
    }

    // MARK: - Editing

    func beginRename(_ id: UUID) {
        guard let block = block(id: id) else { return }
        cancelDrag()
        editor = Editor(block: block, isNew: false, base: block)
    }

    /// Saves the editor. A new block with neither a title nor a task is dropped. A rename writes
    /// only the title and task it changed, into the row as it is now.
    func commitEditor() {
        guard let editor else { return }
        self.editor = nil
        var edited = editor.block
        edited.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.title.isEmpty, let task = model.tasks.task(id: edited.taskID) { edited.title = task.title }
        if editor.isNew {
            guard !edited.title.isEmpty else { return }
            if insert(edited) { selectedBlockID = edited.id }
        } else {
            var change = TimeBlockEdit()
            if !edited.title.isEmpty, edited.title != editor.base.title { change.title = edited.title }
            if edited.taskID != editor.base.taskID { change.taskID = .some(edited.taskID) }
            guard !change.isEmpty else { return }
            edit(edited.id, change, "renaming a block")
        }
    }

    var editorTitle: String {
        get { editor?.block.title ?? "" }
        set { editor?.block.title = newValue }
    }

    func cancelEditor() {
        editor = nil
    }

    /// Picks the editor's task. A title that was blank or the old task's follows the new one.
    func setEditorTask(_ taskID: UUID?) {
        guard var editing = editor else { return }
        let oldTitle = model.tasks.task(id: editing.block.taskID)?.title
        let title = editing.block.title.trimmingCharacters(in: .whitespaces)
        editing.block.taskID = taskID
        if title.isEmpty || title == oldTitle, let task = model.tasks.task(id: taskID) {
            editing.block.title = task.title
        }
        editor = editing
    }

    func link(_ id: UUID, to taskID: UUID?) {
        guard let block = block(id: id), block.taskID != taskID else { return }
        var change = TimeBlockEdit(taskID: .some(taskID))
        if let task = model.tasks.task(id: taskID), block.title.isEmpty { change.title = task.title }
        edit(id, change, "linking a block")
    }

    func setColor(_ id: UUID, _ color: String?) {
        guard let block = block(id: id), block.color != color else { return }
        edit(id, TimeBlockEdit(color: .some(color)), "colouring a block")
    }

    func delete(_ id: UUID) {
        guard block(id: id) != nil else { return }
        if selectedBlockID == id { selectedBlockID = nil }
        if editor?.block.id == id { editor = nil }
        write("deleting a block") { _ = try database.blocks.delete(id: id) }
    }

    func deleteSelected() {
        if let selectedBlockID { delete(selectedBlockID) }
    }

    // MARK: - Focus

    /// ▶: focus on the block's task, or a focus without a task for a block that has none.
    func startFocus(on id: UUID) {
        guard let block = block(id: id) else { return }
        if let taskID = block.taskID {
            model.startFocus(on: taskID)
        } else {
            model.selectTask(nil)
            if !model.isFocusing { model.startFocus() }
        }
    }

    // MARK: - Writing

    @discardableResult
    private func insert(_ block: TimeBlock) -> Bool {
        write("adding a block") { try database.blocks.insert(block) }
    }

    private func edit(_ id: UUID, _ change: TimeBlockEdit, _ what: String) {
        write(what) { try database.blocks.edit(id: id, change) }
    }

    /// Writes, then reads the visible range back: the write shows at once, and a failed one
    /// shows what's actually saved, such as a block deleted elsewhere.
    @discardableResult
    private func write(_ what: String, _ body: () throws -> Void) -> Bool {
        writeCount += 1
        let succeeded = attempt(what, body) != nil
        if succeeded { writeGeneration += 1 }
        reload()
        return succeeded
    }

    @discardableResult
    private func attempt<T>(_ what: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            Self.log.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
