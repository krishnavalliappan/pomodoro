import PomodoroCore
import SwiftUI

/// Quick-add, then today's list, then the way into the planner. The list shows at most
/// `visibleRows` rows and takes only the height they need, so the tab shrinks when it's short.
///
/// Reads `model.tasks`, never `model.snapshot`, so the 1 Hz tick leaves it alone.
struct PopoverTasksTab: View {
    static let visibleRows = 6
    static let rowHeight: CGFloat = 26

    var model: AppModel
    var openPlanner: @MainActor () -> Void
    var quickAddText = ""
    var isEditing: Binding<Bool>?

    private var rows: [TaskItem] { model.tasks.todayByStatus }

    /// Open tasks the popover has no room for. Done ones sort last, so they're never counted.
    static func hiddenOpenCount(_ rows: [TaskItem]) -> Int {
        rows.dropFirst(visibleRows).filter { !$0.isDone }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            QuickAddField(
                model: model,
                text: quickAddText,
                idleLine: AnyView(hint),
                isEditing: isEditing,
                takesFocusRequests: true
            )
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            Button(action: openPlanner) {
                Label("Open Planner", systemImage: "calendar")
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    private var header: some View {
        let open = rows.filter { !$0.isDone }.count
        return HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(.title3.weight(.semibold))
            Spacer()
            if !rows.isEmpty {
                Text(open == 0 ? "All done" : "\(open) open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Holds the preview's line while nothing's typed, so typing doesn't move the list.
    private var hint: some View {
        Text("Return adds it to today")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(height: 16)
            .padding(.leading, 8)
    }

    private var list: some View {
        VStack(spacing: 2) {
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
                    .padding(.leading, 32)
                    .padding(.top, 2)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Nothing planned for today")
                .font(.callout.weight(.medium))
            Text("Type a task above. Add ~2 for an estimate, @14:00 to block time, or tomorrow to plan ahead.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PopoverStyle.surface))
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
        .padding(.horizontal, 8)
        .frame(height: PopoverTasksTab.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(rowFill))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var rowFill: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(PhaseStyle.focusTint.opacity(0.12)) }
        return isHovered ? AnyShapeStyle(PopoverStyle.surface) : AnyShapeStyle(.clear)
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
