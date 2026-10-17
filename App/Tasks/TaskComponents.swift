import AppKit
import CoreTransferable
import PomodoroCore
import SwiftUI

/// What a task row drags: its ID, as plain text so it also drops into other apps. The planner
/// timeline (#11) accepts it with `.dropDestination(for: TaskDragItem.self)`.
struct TaskDragItem: Transferable, Hashable, Sendable {
    let id: UUID

    struct InvalidID: Error {}

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(
            exporting: { (item: TaskDragItem) in item.id.uuidString },
            importing: { (text: String) in
                guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw InvalidID() }
                return TaskDragItem(id: id)
            }
        )
    }

    /// For `List` rows, whose `onMove` only coexists with an item provider, not `draggable`.
    var itemProvider: NSItemProvider {
        NSItemProvider(object: id.uuidString as NSString)
    }
}

/// Estimate vs. actual: one dot per estimated pomodoro, filled as they're done. Pomodoros past
/// the estimate show in the overtime color, so running over reads at a glance. Past `maxDots`
/// a row of dots stops being countable, so it becomes a compact "7/4".
struct EstimateDots: View {
    static let maxDots = 6

    var estimate: Int?
    var actual: Int
    var size: CGFloat = 6

    private var total: Int { max(estimate ?? 0, actual) }
    private var isOver: Bool { estimate.map { actual > $0 } ?? false }

    var body: some View {
        if total > 0 {
            indicator
                .help(accessibilityText)
                .accessibilityElement()
                .accessibilityLabel(accessibilityText)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if total > Self.maxDots {
            Text(countText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(isOver ? AnyShapeStyle(PhaseStyle.overtimeTint) : AnyShapeStyle(.secondary))
                .fixedSize()
        } else {
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { index in
                    Circle()
                        .fill(fill(at: index))
                        .frame(width: size, height: size)
                }
            }
        }
    }

    var countText: String {
        estimate.map { "\(actual)/\($0)" } ?? "\(actual)"
    }

    private func fill(at index: Int) -> AnyShapeStyle {
        guard index < actual else { return AnyShapeStyle(.quaternary) }
        let over = estimate.map { index >= $0 } ?? false
        return AnyShapeStyle(over ? PhaseStyle.overtimeTint : PhaseStyle.focusTint)
    }

    private var accessibilityText: String {
        guard let estimate else { return "\(actual) done" }
        return "\(actual) of \(estimate) done"
    }
}

struct TaskCheckbox: View {
    var isDone: Bool
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isDone ? AnyShapeStyle(PhaseStyle.focusTint) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark as not done" : "Mark as done")
        .accessibilityLabel(isDone ? "Done" : "Not done")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Quick-add with a live readout of what the parser found, so the `~3 @14:00 45m #tag tomorrow`
/// syntax is discoverable by typing.
struct QuickAddField: View {
    var model: AppModel
    var placeholder = "Add a task  ~2 @14:00 45m #tag"
    var toInbox = false
    /// What shows under the field when there's nothing to preview.
    var idleLine: AnyView?
    /// Mirrors keyboard focus, so a host can turn off unmodified shortcuts such as Space.
    var isEditing: Binding<Bool>?
    /// Takes focus when the quick-add hotkey asks; only the popover's field does.
    var takesFocusRequests = false

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        model: AppModel,
        text: String = "",
        toInbox: Bool = false,
        idleLine: AnyView? = nil,
        isEditing: Binding<Bool>? = nil,
        takesFocusRequests: Bool = false
    ) {
        self.model = model
        self.toInbox = toInbox
        self.idleLine = idleLine
        self.isEditing = isEditing
        self.takesFocusRequests = takesFocusRequests
        _text = State(initialValue: text)
    }

    private var parsed: QuickAddResult? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : model.parseQuickAdd(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onChange(of: isFocused) { isEditing?.wrappedValue = isFocused }
                    .onAppear(perform: takeFocusIfRequested)
                    .onChange(of: takesFocusRequests && model.wantsQuickAddFocus) { takeFocusIfRequested() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.clear))
            )

            if let parsed {
                QuickAddPreview(result: parsed, today: model.tasks.today, calendar: model.database.calendar)
            } else if let idleLine {
                idleLine
            }
        }
    }

    private func takeFocusIfRequested() {
        guard takesFocusRequests, model.wantsQuickAddFocus else { return }
        model.quickAddFocusTaken()
        // The popover window is only just key; focus set in the same pass can be dropped.
        Task { @MainActor in isFocused = true }
    }

    private func submit() {
        guard model.addTask(text, toInbox: toInbox) != nil else { return }
        text = ""
    }
}

struct QuickAddPreview: View {
    var result: QuickAddResult
    var today: CivilDay
    var calendar: Calendar

    var body: some View {
        HStack(spacing: 4) {
            if result.title.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Needs a title")
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.chips(for: result, today: today, calendar: calendar), id: \.self) { chip in
                Text(chip)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(PhaseStyle.focusTint.opacity(0.12)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }

    /// "~3", "14:00", "45m", "#work", "tomorrow": the order the syntax is usually typed in.
    static func chips(for result: QuickAddResult, today: CivilDay, calendar: Calendar) -> [String] {
        var chips: [String] = []
        if let estimate = result.estimate { chips.append("~\(estimate)") }
        if let start = result.blockStart {
            let parts = calendar.dateComponents([.hour, .minute], from: start)
            chips.append(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
        }
        if result.blockStart != nil, let duration = result.blockDuration {
            chips.append(durationText(duration))
        }
        if let tag = result.tag { chips.append("#\(tag)") }
        if let day = result.day { chips.append(dayText(day, today: today, calendar: calendar)) }
        return chips
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        switch (minutes / 60, minutes % 60) {
        case (0, let m): return "\(m)m"
        case (let h, 0): return "\(h)h"
        case (let h, let m): return "\(h)h\(m)m"
        }
    }

    static func dayText(_ day: CivilDay, today: CivilDay, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: today.start(in: calendar))
        let offset = calendar.dateComponents([.day], from: start, to: day.start(in: calendar)).day ?? 0
        switch offset {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2..<7:
            let weekday = calendar.component(.weekday, from: day.start(in: calendar))
            return calendar.shortWeekdaySymbols[weekday - 1]
        default: return day.isoString
        }
    }
}
