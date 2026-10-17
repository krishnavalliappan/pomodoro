import PomodoroCore
import SwiftUI

/// The full task list: quick-add, then Today, Inbox and Upcoming, which is grouped by day. Rows
/// reorder by drag within a section (within a day in Upcoming), edit inline when selected, and
/// drag out as `TaskDragItem`s for the timeline (#11).
struct TaskListView: View {
    static let upcomingExpandedKey = "planner.upcomingExpanded"

    var model: AppModel

    @State private var selection: TaskItem.ID?
    @AppStorage private var isUpcomingExpanded: Bool

    init(model: AppModel, selection: TaskItem.ID? = nil, defaults: UserDefaults = .standard) {
        self.model = model
        _selection = State(initialValue: selection)
        _isUpcomingExpanded = AppStorage(wrappedValue: true, Self.upcomingExpandedKey, store: defaults)
    }

    private var tasks: TaskStore { model.tasks }

    var body: some View {
        VStack(spacing: 0) {
            QuickAddField(model: model)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            List(selection: $selection) {
                section("Today", tasks.overview.today, empty: "Nothing planned for today")
                section("Inbox", tasks.overview.inbox, empty: "Tasks without a day land here")
                if !tasks.overview.upcoming.isEmpty {
                    upcoming
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                if let selection { model.deleteTask(selection) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TaskItem], empty: String) -> some View {
        Section {
            if items.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            rows(items)
        } header: {
            header(title, open: items.filter { !$0.isDone }.count)
        }
    }

    /// One run of rows per day. Each `ForEach` moves only its own rows, and the store orders by
    /// day first, so a drag can't land a task among another day's.
    private var upcoming: some View {
        let groups = tasks.overview.upcomingByDay
        return Section(isExpanded: $isUpcomingExpanded) {
            ForEach(groups) { group in
                Text(QuickAddPreview.dayText(group.day, today: tasks.today, calendar: model.database.calendar).capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .selectionDisabled()
                rows(group.tasks)
            }
        } header: {
            header("Upcoming", open: tasks.overview.upcoming.count)
        }
    }

    private func rows(_ items: [TaskItem]) -> some View {
        ForEach(items) { task in
            TaskListRow(
                task: task,
                actuals: tasks.actuals(for: task.id),
                isSelected: selection == task.id,
                isCurrent: model.selectedTaskID == task.id,
                model: model
            )
            .tag(task.id)
            .itemProvider { TaskDragItem(id: task.id).itemProvider }
            .contextMenu { menu(for: task) }
        }
        .onMove { from, to in
            var ids = items.map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            tasks.reorder(ids)
        }
    }

    private func header(_ title: String, open: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            if open > 0 {
                Text("\(open)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func menu(for task: TaskItem) -> some View {
        Button(model.isFocusing ? "Switch Focus to This Task" : "Start Focus") { model.startFocus(on: task.id) }
            .disabled(task.isDone)
        Button(task.isDone ? "Mark as Not Done" : "Mark as Done") { tasks.setDone(task.id, !task.isDone) }
        Divider()
        let today = tasks.today
        Button("Schedule for Today") { tasks.schedule(task.id, on: today) }
            .disabled(task.scheduledDay == today)
        Button("Schedule for Tomorrow") { tasks.schedule(task.id, on: tasks.tomorrow) }
        Button("Move to Inbox") { tasks.schedule(task.id, on: nil) }
            .disabled(task.scheduledDay == nil)
        Divider()
        Button("Delete", role: .destructive) { model.deleteTask(task.id) }
    }
}

struct TaskListRow: View {
    var task: TaskItem
    var actuals: TaskActuals
    var isSelected: Bool
    var isCurrent: Bool
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TaskCheckbox(isDone: task.isDone) {
                    model.tasks.setDone(task.id, !task.isDone)
                }
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.title)
                if isCurrent {
                    Image(systemName: "timer")
                        .foregroundStyle(PhaseStyle.focusTint)
                        .help("The current task")
                }
                Spacer(minLength: 4)
                if let tag = task.tag {
                    Text("#\(tag)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                EstimateDots(estimate: task.estimatePomodoros, actual: actuals.completedPomodoros)
            }
            if isSelected {
                TaskEditor(task: task) { [id = task.id] in model.tasks.edit(id, $0) }
                    .padding(.leading, 24)
            } else if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Inline edits, saved on Return and when the row is deselected. Unsaved text survives other
/// changes to the row, and only the edited fields are written.
struct TaskEditor: View {
    var task: TaskItem
    var save: @MainActor (TaskEdit) -> Void

    @State private var draft: TaskDraft

    init(task: TaskItem, save: @escaping @MainActor (TaskEdit) -> Void) {
        self.task = task
        self.save = save
        _draft = State(initialValue: TaskDraft(task))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            TextField("Notes", text: $draft.notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(commit)
            HStack(spacing: 6) {
                Text("Estimate")
                    .foregroundStyle(.secondary)
                Stepper(value: estimate, in: 0...20) {
                    Text(draft.estimatePomodoros.map { $0 == 1 ? "1 pomodoro" : "\($0) pomodoros" } ?? "None")
                        .monospacedDigit()
                }
            }
            .font(.callout)
        }
        .onDisappear(perform: commit)
        .onChange(of: task) { draft.rebase(onto: task) }
    }

    private var estimate: Binding<Int> {
        Binding(
            get: { draft.estimatePomodoros ?? 0 },
            set: { value in
                draft.estimatePomodoros = value == 0 ? nil : value
                commit()
            }
        )
    }

    private func commit() {
        if let edit = draft.edit { save(edit) }
    }
}
