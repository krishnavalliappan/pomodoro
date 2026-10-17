import Foundation
import Observation
import PomodoroCore
import os

/// The planner timeline's day: its blocks, the drag in progress, and the inline editor.
///
/// Drags only touch `drag`, so the dragged block follows the pointer without a database write;
/// the drop writes once. Writes show at once through `overrides`, which hide the observation's
/// stale values until it catches up, so a dropped block never jumps back.
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
        var block: TimeBlock
        var isNew: Bool
    }

    private(set) var day: CivilDay
    private(set) var layout: TimelineLayout
    private(set) var drag: Drag?
    var editor: Editor?
    var selectedBlockID: UUID?
    /// The block whose ▶ started the current focus, so it highlights even outside its time.
    private(set) var startedBlockID: UUID?

    private var observed: [TimeBlock] = []
    /// Local writes the observation hasn't delivered yet; `nil` is a delete.
    private var overrides: [UUID: TimeBlock?] = [:]

    @ObservationIgnored let model: AppModel
    private var clock: any TimeSource { model.clock }
    /// Database writes made, for tests that check a drag writes only on drop.
    @ObservationIgnored private(set) var writeCount = 0
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

    /// What's on the timeline: saved blocks, local writes on top, and the drag's preview.
    var blocks: [TimeBlock] {
        var byID = Dictionary(observed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, block) in overrides { byID[id] = block }
        if let drag { byID[drag.preview.id] = drag.preview }
        if let editor, editor.isNew { byID[editor.block.id] = editor.block }
        return byID.values.sorted { ($0.start, $0.duration, $0.id.uuidString) < ($1.start, $1.duration, $1.id.uuidString) }
    }

    func block(id: UUID?) -> TimeBlock? {
        guard let id else { return nil }
        return blocks.first { $0.id == id }
    }

    /// The block a focus is running on: the one its ▶ started, or one scheduled now for the
    /// focused task (or for no task, during a focus without one).
    func isRunning(_ block: TimeBlock) -> Bool {
        guard model.isFocusing else { return false }
        if block.id == startedBlockID { return true }
        return block.contains(now) && block.taskID == model.selectedTaskID
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
        observed = []
        overrides = [:]
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
        for await value in database.blocks.observe(in: layout.visible) {
            guard self.generation == generation, !Task.isCancelled else { return }
            apply(value)
        }
    }

    private func reload() {
        attempt("reading blocks") { apply(try database.blocks.blocks(in: layout.visible)) }
    }

    private func apply(_ value: [TimeBlock]) {
        // Drop overrides the database now agrees with; keep the rest over stale values.
        let saved = Dictionary(value.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let settled = overrides.filter { id, block in saved[id] == block }.map(\.key)
        for id in settled { overrides[id] = nil }
        if value != observed {
            observed = value
            for id in Set(value.compactMap(\.taskID)) { model.tasks.ensureLoaded(id) }
        }
        // The popover suggests the task of the block scheduled now; a write here can change it.
        if isToday { model.tasks.refreshSuggestion() }
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
            editor = Editor(block: drag.preview, isNew: true)
        case .move, .resize:
            selectedBlockID = drag.preview.id
            guard drag.preview != drag.original else { return }
            let preview = drag.preview
            write(preview, "moving a block") {
                if drag.kind == .move {
                    try database.blocks.move(id: preview.id, to: preview.start)
                } else {
                    try database.blocks.resize(id: preview.id, duration: preview.duration)
                }
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
        editor = Editor(block: block, isNew: false)
    }

    /// Saves the editor. A new block with neither a title nor a task is dropped.
    func commitEditor() {
        guard var edited = editor?.block, let isNew = editor?.isNew else { return }
        editor = nil
        edited.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if edited.title.isEmpty, let task = model.tasks.task(id: edited.taskID) { edited.title = task.title }
        if isNew {
            guard !edited.title.isEmpty else { return }
            if insert(edited) { selectedBlockID = edited.id }
        } else {
            guard !edited.title.isEmpty, edited != block(id: edited.id) else { return }
            update(edited, "renaming a block")
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
        guard var block = block(id: id), block.taskID != taskID else { return }
        block.taskID = taskID
        if let task = model.tasks.task(id: taskID), block.title.isEmpty { block.title = task.title }
        update(block, "linking a block")
    }

    func setColor(_ id: UUID, _ color: String?) {
        guard var block = block(id: id), block.color != color else { return }
        block.color = color
        update(block, "colouring a block")
    }

    func delete(_ id: UUID) {
        guard block(id: id) != nil else { return }
        if selectedBlockID == id { selectedBlockID = nil }
        if editor?.block.id == id { editor = nil }
        overrides[id] = .some(nil)
        writeCount += 1
        if attempt("deleting a block", { try database.blocks.delete(id: id) }) == nil {
            overrides[id] = nil
        }
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
        startedBlockID = block.id
    }

    // MARK: - Writing

    @discardableResult
    private func insert(_ block: TimeBlock) -> Bool {
        write(block, "adding a block") { try database.blocks.insert(block) }
    }

    private func update(_ block: TimeBlock, _ what: String) {
        write(block, what) { try database.blocks.update(block) }
    }

    /// Shows `block` at once, then writes it; a failed write puts the saved value back.
    @discardableResult
    private func write(_ block: TimeBlock, _ what: String, _ body: () throws -> Void) -> Bool {
        let previous = overrides[block.id]
        overrides[block.id] = block
        writeCount += 1
        guard attempt(what, body) != nil else {
            overrides[block.id] = previous
            return false
        }
        if isToday { model.tasks.refreshSuggestion() }
        return true
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
