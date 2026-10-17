import PomodoroCore
import SwiftUI

// Each of these reads `model.tasks`, never `model.snapshot`, and the popover's own body never
// reads `model.tasks`: a task change leaves the timer alone, and the 1 Hz tick leaves these alone.

/// The current task, switchable at any time. The block scheduled now comes first.
struct TaskPickerLine: View {
    var model: AppModel

    private var tasks: TaskStore { model.tasks }
    private var selected: UUID? { model.selectedTaskID }

    private var suggestion: TaskItem? {
        guard let id = tasks.suggestedTaskID, id != selected, let task = tasks.task(id: id), !task.isDone else { return nil }
        return task
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                menuContent
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.secondary)
                    Text(model.currentTaskTitle ?? "No task")
                        .foregroundStyle(model.currentTaskTitle == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help(model.isFocusing ? "Switch the task this focus counts toward" : "Choose a task for the next focus")
            .accessibilityLabel("Current task")
            .accessibilityValue(model.currentTaskTitle ?? "No task")

            Spacer(minLength: 0)

            if selected == nil, let suggestion {
                Button {
                    model.selectTask(suggestion.id)
                } label: {
                    Label(suggestion.title, systemImage: "calendar.badge.clock")
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Scheduled now: work on “\(suggestion.title)”")
            }
        }
        .font(.callout)
        .frame(height: 22)
    }

    @ViewBuilder
    private var menuContent: some View {
        if let suggestion {
            Section("Scheduled now") {
                item(suggestion)
            }
        }
        let today = tasks.overview.today.filter { !$0.isDone && $0.id != suggestion?.id }
        if !today.isEmpty {
            Section("Today") {
                ForEach(today) { item($0) }
            }
        }
        let inbox = tasks.overview.inbox.filter { !$0.isDone && $0.id != suggestion?.id }
        if !inbox.isEmpty {
            Section("Inbox") {
                ForEach(inbox.prefix(10)) { item($0) }
            }
        }
        Divider()
        Button("No task") { model.selectTask(nil) }
            .disabled(selected == nil)
    }

    private func item(_ task: TaskItem) -> some View {
        Button {
            model.selectTask(task.id)
        } label: {
            if task.id == selected {
                Label(task.title, systemImage: "checkmark")
            } else {
                Text(task.title)
            }
        }
    }
}

/// Quick-add, today's progress, and the top of today's list.
///
/// Equatable on the model alone: the closure and binding never change for one popover, but
/// SwiftUI can't tell, and would re-run this body on every tick of the timer above it.
struct PopoverTaskSection: View, Equatable {
    static let visibleRows = 5
    static let rowHeight: CGFloat = 22

    var model: AppModel
    var openPlanner: @MainActor () -> Void
    var quickAddText = ""
    var isEditing: Binding<Bool>?

    private var rows: [TaskItem] { model.tasks.todayByStatus }

    // SwiftUI compares views on the main thread.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated { lhs.model === rhs.model && lhs.quickAddText == rhs.quickAddText }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuickAddField(
                model: model,
                text: quickAddText,
                idleLine: AnyView(TodayRow(completed: model.completedToday, cycle: model.longBreakEvery)),
                isEditing: isEditing
            )
            VStack(spacing: 0) {
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows.prefix(Self.visibleRows)) { task in
                        PopoverTaskRow(
                            task: task,
                            actuals: model.tasks.actuals(for: task.id),
                            isCurrent: task.id == model.selectedTaskID,
                            isFocusing: model.isFocusing,
                            model: model
                        )
                    }
                    if rows.count > Self.visibleRows {
                        Button("\(rows.count - Self.visibleRows) more in Planner", action: openPlanner)
                            .buttonStyle(.link)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 26)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight + 16, alignment: .top)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Nothing planned for today")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Type a task above. Add ~2 for an estimate,\n@14:00 to block time, or tomorrow to plan ahead.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}

struct PopoverTaskRow: View {
    var task: TaskItem
    var actuals: TaskActuals
    var isCurrent: Bool
    var isFocusing: Bool
    var model: AppModel

    @State private var isHovered = false

    var body: some View {
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
            Spacer(minLength: 4)
            EstimateDots(estimate: task.estimatePomodoros, actual: actuals.completedPomodoros)
            startButton
                .opacity(isHovered && !task.isDone && !(isCurrent && isFocusing) ? 1 : 0)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(height: PopoverTaskSection.rowHeight)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(rowFill))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var rowFill: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(PhaseStyle.focusTint.opacity(0.12)) }
        return isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)
    }

    private var startButton: some View {
        Button {
            model.startFocus(on: task.id)
        } label: {
            Image(systemName: isFocusing ? "arrow.triangle.swap" : "play.fill")
                .foregroundStyle(PhaseStyle.focusTint)
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .help(isFocusing ? "Switch this focus to “\(task.title)”" : "Start focus on “\(task.title)”")
        .accessibilityLabel(isFocusing ? "Switch focus to \(task.title)" : "Start focus on \(task.title)")
    }
}
