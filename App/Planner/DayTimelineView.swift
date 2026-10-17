import AppKit
import PomodoroCore
import SwiftUI

/// The planner's day: an hour grid with blocks laid out by `TimelineLayout`. Drag empty space to
/// create a block, drag a block to move it or its bottom edge to resize it, and drop a task from
/// the sidebar to block time for it.
struct DayTimelineView: View {
    static let gutter: CGFloat = 52
    private static let space = "timeline"

    @Bindable var store: TimelineStore

    @State private var isDropTargeted = false
    @FocusState private var isFocused: Bool

    private var layout: TimelineLayout { store.layout }

    var body: some View {
        VStack(spacing: 0) {
            TimelineHeader(store: store)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    canvas
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                }
                .onAppear { proxy.scrollTo(store.initialScrollHour, anchor: .top) }
                .onChange(of: store.day) { proxy.scrollTo(store.initialScrollHour, anchor: .top) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onDeleteCommand { store.deleteSelected() }
        .onExitCommand {
            store.cancelDrag()
            store.cancelEditor()
        }
        .task(id: store.day) { await store.observe() }
    }

    private var canvas: some View {
        // Once a minute is enough for the now line and the running highlight.
        SwiftUI.TimelineView(.everyMinute) { _ in
            ZStack(alignment: .topLeading) {
                HourGrid(layout: layout, calendar: store.calendar, gutter: Self.gutter)
                blocksArea
                    .padding(.leading, Self.gutter)
                    .padding(.trailing, 10)
                if store.isToday, store.layout.visible.contains(store.now) {
                    NowLine()
                        .padding(.leading, Self.gutter - 4)
                        .offset(y: layout.y(for: store.now) - 4)
                        .allowsHitTesting(false)
                }
                if store.editor != nil {
                    BlockEditorCard(store: store)
                        .offset(x: Self.gutter + 12, y: editorY)
                }
            }
            .frame(height: layout.totalHeight, alignment: .top)
            .coordinateSpace(name: Self.space)
        }
    }

    private var blocksArea: some View {
        let blocks = store.blocks
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(createGesture)
                .onTapGesture {
                    store.selectedBlockID = nil
                    isFocused = true
                }
            BlockColumns {
                ForEach(layout.frames(for: blocks)) { frame in
                    if let block = byID[frame.id] {
                        blockView(block, frame: frame)
                            .layoutValue(key: BlockSlot.self, value: frame)
                    }
                }
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: TaskDragItem.self) { items, location in
            guard let item = items.first else { return false }
            return store.dropTask(item.id, at: layout.date(atY: location.y)) != nil
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private func blockView(_ block: TimeBlock, frame: TimelineLayout.Frame) -> some View {
        let task = store.model.tasks.task(id: block.taskID)
        let isDraft = store.drag?.kind == .create && store.drag?.preview.id == block.id
            || store.editor.map { $0.isNew && $0.block.id == block.id } ?? false
        let view = TimelineBlockView(
            block: block,
            frame: frame,
            task: task,
            actual: task.map { store.model.tasks.actuals(for: $0.id).completedPomodoros } ?? 0,
            calendar: store.calendar,
            isSelected: store.selectedBlockID == block.id,
            isRunning: store.isRunning(block),
            isDraft: isDraft,
            isDragging: store.drag?.preview.id == block.id,
            play: { store.startFocus(on: block.id) }
        )
        if isDraft {
            view.allowsHitTesting(false)
        } else {
            view
                .overlay(alignment: .bottom) { ResizeHandle(gesture: resizeGesture(block.id)) }
                .gesture(moveGesture(block.id))
                .onTapGesture {
                    store.selectedBlockID = block.id
                    isFocused = true
                }
                .contextMenu { menu(for: block) }
        }
    }

    // MARK: - Gestures

    private func moveGesture(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { store.dragMove(id, by: layout.interval(forHeight: $0.translation.height)) }
            .onEnded { _ in store.endDrag() }
    }

    private func resizeGesture(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { store.dragResize(id, by: layout.interval(forHeight: $0.translation.height)) }
            .onEnded { _ in store.endDrag() }
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                store.dragCreate(from: layout.date(atY: value.startLocation.y), to: layout.date(atY: value.location.y))
            }
            .onEnded { _ in store.endDrag() }
    }

    // MARK: - Menu

    @ViewBuilder
    private func menu(for block: TimeBlock) -> some View {
        Button(block.taskID == nil ? "Start Focus" : "Start Focus on Task") { store.startFocus(on: block.id) }
        Button("Rename…") { store.beginRename(block.id) }
        Divider()
        Menu("Link Task") {
            ForEach(store.linkableTasks) { task in
                Toggle(task.title, isOn: Binding(
                    get: { block.taskID == task.id },
                    set: { _ in store.link(block.id, to: task.id) }
                ))
            }
        }
        .disabled(store.linkableTasks.isEmpty)
        Button("Unlink Task") { store.link(block.id, to: nil) }
            .disabled(block.taskID == nil)
        Menu("Color") {
            Toggle("Accent", isOn: Binding(get: { block.color == nil }, set: { _ in store.setColor(block.id, nil) }))
            Divider()
            ForEach(BlockPalette.tokens, id: \.self) { token in
                Toggle(token.capitalized, isOn: Binding(
                    get: { block.color == token },
                    set: { _ in store.setColor(block.id, token) }
                ))
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(block.id) }
    }

    /// Below the block being edited, or above it when that would run off the bottom.
    private var editorY: CGFloat {
        guard let block = store.editor?.block else { return 0 }
        let below = layout.y(for: block.end) + 4
        if below + BlockEditorCard.height <= layout.totalHeight { return below }
        return max(0, layout.y(for: block.start) - BlockEditorCard.height - 4)
    }
}

extension TimelineStore {
    /// The hour row to show first: the one before now on today, otherwise the first block's, or 08:00.
    var initialScrollHour: Int {
        let anchor = isToday ? now - 3600 : blocks.first?.start ?? layout.visible.lowerBound + 2 * 3600
        let index = Int((anchor.timeIntervalSince(layout.visible.lowerBound) / 3600).rounded(.down))
        return min(max(index, 0), max(layout.hourMarks.count - 1, 0))
    }
}

// MARK: - Header

struct TimelineHeader: View {
    var store: TimelineStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TimelineFormat.dayTitle(store.day, calendar: store.calendar))
                    .font(.title3.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button(action: store.showPreviousDay) {
                    Image(systemName: "chevron.left")
                }
                .help("Previous day")
                .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Today", action: store.showToday)
                    .disabled(store.isToday)
                    .keyboardShortcut("t", modifiers: .command)
                Button(action: store.showNextDay) {
                    Image(systemName: "chevron.right")
                }
                .help("Next day")
                .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let blocks = store.blocks.filter { $0.duration > 0 && !$0.title.isEmpty }
        guard !blocks.isEmpty else { return "Drag on the timeline to block time, or drop a task here" }
        let total = blocks.reduce(0) { $0 + $1.duration }
        let count = blocks.count == 1 ? "1 block" : "\(blocks.count) blocks"
        return "\(count) · \(QuickAddPreview.durationText(total)) planned"
    }
}

// MARK: - Grid

struct HourGrid: View {
    var layout: TimelineLayout
    var calendar: Calendar
    var gutter: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(layout.hourMarks.enumerated()), id: \.offset) { index, mark in
                HStack(alignment: .top, spacing: 0) {
                    Text(TimelineFormat.time(mark, calendar: calendar))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 10, alignment: .trailing)
                        .padding(.trailing, 6)
                        .offset(y: -7)
                    VStack(spacing: 0) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                        Spacer(minLength: 0)
                        Rectangle().fill(.quaternary.opacity(0.5)).frame(height: 1)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: layout.hourHeight)
                .id(index)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1).padding(.leading, gutter - 4)
        }
        .accessibilityHidden(true)
    }
}

struct NowLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(PhaseStyle.focusTint)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(PhaseStyle.focusTint)
                .frame(height: 1.5)
        }
        .frame(height: 8)
        .accessibilityLabel("Now")
    }
}

// MARK: - Blocks

/// Places each block at its `TimelineLayout.Frame`: y and height in points, x and width as
/// fractions of the column area.
struct BlockColumns: Layout {
    var gap: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            guard let frame = subview[BlockSlot.self] else { continue }
            let x = bounds.minX + bounds.width * frame.column.x
            let width = max(bounds.width * frame.column.width - gap, 1)
            // A hairline gap keeps back-to-back blocks apart.
            let height = max(frame.height - 1, 1)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + frame.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

private struct BlockSlot: LayoutValueKey {
    static let defaultValue: TimelineLayout.Frame? = nil
}

struct TimelineBlockView: View {
    var block: TimeBlock
    var frame: TimelineLayout.Frame
    var task: TaskItem?
    var actual: Int
    var calendar: Calendar
    var isSelected = false
    var isRunning = false
    var isDraft = false
    var isDragging = false
    var play: @MainActor () -> Void = {}

    private var tint: Color { BlockPalette.color(block.color) }
    private var title: String { block.title.isEmpty ? "New block" : block.title }
    private var isRoomy: Bool { frame.height >= 36 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            content
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .padding(.vertical, isRoomy ? 4 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 6, y: 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(TimelineFormat.range(block, calendar: calendar))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(tint.opacity(isRunning ? 0.34 : isDraft ? 0.08 : 0.18))
            Rectangle()
                .fill(tint)
                .frame(width: 3)
            if isDraft {
                shape.strokeBorder(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            } else if isSelected || isRunning {
                shape.strokeBorder(tint, lineWidth: isRunning ? 2 : 1.5)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRoomy {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    titleText
                    Spacer(minLength: 2)
                    if !isDraft { playButton }
                }
                HStack(spacing: 6) {
                    if isRunning { runningBadge }
                    Text(TimelineFormat.range(block, calendar: calendar))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let task {
                        EstimateDots(estimate: task.estimatePomodoros, actual: actual, size: 5)
                    }
                }
                .font(.caption)
            }
        } else {
            HStack(spacing: 6) {
                titleText
                Text(TimelineFormat.range(block, calendar: calendar))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 2)
                if isRunning { runningBadge }
                if !isDraft && frame.height >= 18 { playButton }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(block.title.isEmpty ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var runningBadge: some View {
        Image(systemName: "timer")
            .font(.caption)
            .foregroundStyle(tint)
            .help("Focusing now")
    }

    private var playButton: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task == nil ? "Start a focus" : "Start a focus on \(task?.title ?? "")")
        .accessibilityLabel("Start focus")
    }
}

/// The bottom edge of a block, which resizes it.
private struct ResizeHandle<G: Gesture>: View {
    var gesture: G

    var body: some View {
        Color.clear
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(gesture)
    }
}

// MARK: - Editor

/// The inline title field and task picker for a new block, or for renaming one.
struct BlockEditorCard: View {
    static let height: CGFloat = 132
    static let width: CGFloat = 280

    @Bindable var store: TimelineStore
    @FocusState private var isTitleFocused: Bool

    private var isNew: Bool { store.editor?.isNew ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let block = store.editor?.block {
                Text("\(isNew ? "New block" : "Rename") · \(TimelineFormat.range(block, calendar: store.calendar))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            TextField("Title", text: $store.editorTitle)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .onSubmit(store.commitEditor)
            Picker("Task", selection: task) {
                Text("No task").tag(UUID?.none)
                if !taskOptions.isEmpty { Divider() }
                ForEach(taskOptions) { task in
                    Text(task.title).tag(UUID?.some(task.id))
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Cancel", action: store.cancelEditor)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: store.commitEditor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .onAppear { isTitleFocused = true }
    }

    private var canCommit: Bool {
        guard let block = store.editor?.block else { return false }
        return !block.title.trimmingCharacters(in: .whitespaces).isEmpty || block.taskID != nil
    }

    /// The linkable tasks, plus the current one if it isn't among them, such as a done task.
    private var taskOptions: [TaskItem] {
        var options = store.linkableTasks
        if let current = store.model.tasks.task(id: store.editor?.block.taskID), !options.contains(where: { $0.id == current.id }) {
            options.insert(current, at: 0)
        }
        return options
    }

    private var task: Binding<UUID?> {
        Binding(get: { store.editor?.block.taskID }, set: { store.setEditorTask($0) })
    }
}

// MARK: - Styling

enum BlockPalette {
    static let tokens = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "gray"]

    /// `nil` and unknown tokens follow the system accent.
    static func color(_ token: String?) -> Color {
        switch token {
        case "red": Color(nsColor: .systemRed)
        case "orange": Color(nsColor: .systemOrange)
        case "yellow": Color(nsColor: .systemYellow)
        case "green": Color(nsColor: .systemGreen)
        case "teal": Color(nsColor: .systemTeal)
        case "blue": Color(nsColor: .systemBlue)
        case "purple": Color(nsColor: .systemPurple)
        case "pink": Color(nsColor: .systemPink)
        case "gray": Color(nsColor: .systemGray)
        default: .accentColor
        }
    }
}

enum TimelineFormat {
    /// 24-hour "09:30" in the store's time zone, like the quick-add chips.
    static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func range(_ block: TimeBlock, calendar: Calendar) -> String {
        "\(time(block.start, calendar: calendar))–\(time(block.end, calendar: calendar))"
    }

    static func dayTitle(_ day: CivilDay, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.timeZone = calendar.timeZone
        let noon = calendar.date(byAdding: .hour, value: 12, to: day.start(in: calendar)) ?? day.start(in: calendar)
        return noon.formatted(style)
    }
}
