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
        HStack(spacing: 6) {
            // Plain styles, so the label draws the same field whatever the state; the system
            // button styles restyle the text differently for an empty and a chosen task.
            Menu {
                menuContent
            } label: {
                PickerField(symbol: "checklist", title: model.currentTaskTitle ?? "No task", isPlaceholder: model.currentTaskTitle == nil, showsChevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .help(model.isFocusing ? "Switch the task this focus counts toward" : "Choose a task for the next focus")
            .accessibilityLabel("Current task")
            .accessibilityValue(model.currentTaskTitle ?? "No task")

            if selected == nil, let suggestion {
                Button {
                    model.selectTask(suggestion.id)
                } label: {
                    PickerField(symbol: "calendar.badge.clock", title: suggestion.title, isPlaceholder: false, showsChevron: false)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 140, alignment: .trailing)
                .help("Scheduled now: work on “\(suggestion.title)”")
                .accessibilityLabel("Work on \(suggestion.title), scheduled now")
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

/// The picker's look: one rounded field shared by the current task and the suggestion.
struct PickerField: View {
    var symbol: String
    var title: String
    var isPlaceholder: Bool
    var showsChevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsChevron {
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)))
        .contentShape(Rectangle())
    }
}

/// Quick-add, today's progress, and the top of today's list, which collapses to its header.
/// It takes only the height its rows need, so the popover shrinks when it's collapsed or empty.
///
/// Equatable on its plain inputs: the closure and binding never change for one popover, but
/// SwiftUI can't tell, and would re-run this body on every tick of the timer above it.
struct PopoverTaskSection: View, Equatable {
    static let visibleRows = 5
    static let rowHeight: CGFloat = 22
    static let expandedKey = "popover.todayExpanded"

    var model: AppModel
    var openPlanner: @MainActor () -> Void
    var quickAddText = ""
    var isEditing: Binding<Bool>?
    var defaults: UserDefaults

    @AppStorage private var isExpanded: Bool

    init(
        model: AppModel,
        openPlanner: @escaping @MainActor () -> Void,
        quickAddText: String = "",
        isEditing: Binding<Bool>? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.model = model
        self.openPlanner = openPlanner
        self.quickAddText = quickAddText
        self.isEditing = isEditing
        self.defaults = defaults
        _isExpanded = AppStorage(wrappedValue: true, Self.expandedKey, store: defaults)
    }

    private var rows: [TaskItem] { model.tasks.todayByStatus }

    // SwiftUI compares views on the main thread.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model && lhs.quickAddText == rhs.quickAddText && lhs.defaults === rhs.defaults
        }
    }

    /// Open tasks the popover has no room for. Done ones sort last, so they're never counted.
    static func hiddenOpenCount(_ rows: [TaskItem]) -> Int {
        rows.dropFirst(visibleRows).filter { !$0.isDone }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuickAddField(
                model: model,
                text: quickAddText,
                idleLine: AnyView(TodayRow(summary: model.today, cycle: model.longBreakEvery)),
                isEditing: isEditing,
                takesFocusRequests: true
            )
            if rows.isEmpty {
                emptyState
            } else {
                disclosure
                if isExpanded {
                    VStack(spacing: 0) {
                        ForEach(rows.prefix(Self.visibleRows)) { task in
                            PopoverTaskRow(
                                task: task,
                                actuals: model.tasks.actuals(for: task.id),
                                isCurrent: task.id == model.selectedTaskID,
                                isFocusing: model.isFocusing,
                                model: model
                            )
                        }
                        let hidden = Self.hiddenOpenCount(rows)
                        if hidden > 0 {
                            Button("\(hidden) more in Planner", action: openPlanner)
                                .buttonStyle(.link)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 26)
                                .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }

    private var disclosure: some View {
        let open = rows.filter { !$0.isDone }.count
        return Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Text("Today's tasks")
                Spacer(minLength: 4)
                Text(open == 0 ? "All done" : "\(open) open")
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide today's tasks" : "Show today's tasks")
        .accessibilityLabel("Today's tasks, \(open) open")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var emptyState: some View {
        VStack(spacing: 2) {
            Text("Nothing planned for today")
                .font(.callout.weight(.medium))
            Text("Type a task above. Add ~2 for an estimate, @14:00 to block time, or tomorrow to plan ahead.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
                .help(task.title)
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
