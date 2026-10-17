import AppKit
import PomodoroCore
import SwiftUI

/// The hero tab: the phase and round, a large dial, the task, and one prominent action.
///
/// This body reads `model.stage`, never `model.snapshot`, so it only re-renders at a phase or
/// status change. The per-second readout lives in `TimerDial`, the one view the tick reaches.
struct PopoverTimerTab: View {
    var model: AppModel

    private var stage: AppModel.TimerStage { model.stage }
    private var style: PhaseStyle { PhaseStyle(stage) }
    private var isPaused: Bool { stage.status == .paused }

    var body: some View {
        VStack(spacing: 0) {
            header
            TimerDial(
                model: model,
                tint: style.tint,
                isDimmed: isPaused,
                diameter: model.prompt == nil ? 176 : 124,
                caption: caption
            )
            .padding(.top, 12)
            CurrentTaskLine(model: model)
                .padding(.top, 14)
            Group {
                if let prompt = model.prompt {
                    DecisionCard(prompt: prompt, model: model, style: style)
                } else {
                    controls
                }
            }
            .padding(.top, 14)
            // Presets set up the next focus, so they only show before one.
            if stage.phase == .idle {
                PresetRow(model: model, tint: PhaseStyle.focusTint)
                    .padding(.top, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(style.tint)
                .frame(width: 8, height: 8)
            Text(style.title)
                .font(.subheadline.weight(.semibold))
            if isPaused {
                Text("· Paused")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            RoundDots(cycle: model.longBreakEvery, stage: stage)
        }
        .frame(height: 18)
    }

    private var caption: String {
        if stage.phase == .idle { return "Ready" }
        switch stage.status {
        case .paused: return "Paused"
        case .overtime: return "Overtime"
        case .awaitingDecision: return "Time's up"
        case .running: return stage.phase == .focus ? "Until break" : "Until focus"
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            primaryControl
            if stage.phase != .idle {
                secondaryControls
            }
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        switch (stage.phase, stage.status) {
        case (.idle, _):
            pill("Start focus", symbol: "play.fill", action: model.startFocus)
        case (_, .paused):
            pill("Resume", symbol: "play.fill", action: model.resume)
        case (.focus, .overtime):
            // Kept going past the prompt: the break is still the natural next step.
            pill("Start break", symbol: "cup.and.saucer.fill", action: model.startBreak)
        case (_, .overtime):
            pill("Start focus", symbol: "play.fill", action: model.startFocus)
        default:
            pill("Pause", symbol: "pause.fill", action: model.pause)
        }
    }

    @ViewBuilder
    private var secondaryControls: some View {
        if case .overtime = stage.status {
            GhostCircleButton(symbol: "pause.fill", help: "Pause", action: model.pause)
        } else {
            if stage.status == .running {
                GhostCircleButton(text: "+5", help: "Add 5 minutes") { model.extend(minutes: 5) }
            }
            GhostCircleButton(symbol: "forward.end.fill", help: stage.phase == .focus ? "Skip to break" : "Skip to focus", action: model.skip)
        }
        GhostCircleButton(symbol: "stop.fill", help: stage.phase == .focus ? "Stop and log (⌘.)" : "Stop (⌘.)", action: model.stopAndLog)
    }

    private func pill(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(PillButtonStyle(fill: style.fill))
    }
}

// MARK: - Styling

struct PhaseStyle {
    static let focusTint = Color(nsColor: .systemRed)
    static let breakTint = Color(nsColor: .systemTeal)
    static let overtimeTint = Color(nsColor: .systemOrange)

    // Button fills: each tint darkened until a white label reaches 4.5:1 (5.2–5.7:1). The system
    // tints only manage 2–3.6:1. Fixed, because the fill sits under white text in both appearances.
    static let focusFill = Color(red: 0xC4 / 255, green: 0x28 / 255, blue: 0x1C / 255)
    static let breakFill = Color(red: 0x00 / 255, green: 0x78 / 255, blue: 0x8A / 255)
    static let overtimeFill = Color(red: 0xB2 / 255, green: 0x50 / 255, blue: 0x00 / 255)

    var title: String
    var tint: Color
    var fill: Color

    init(_ stage: AppModel.TimerStage) {
        title =
            switch stage.phase {
            case .idle: "Ready to focus"
            case .focus: "Focus"
            case .shortBreak: "Short break"
            case .longBreak: "Long break"
            }
        if stage.isOvertime {
            tint = Self.overtimeTint
            fill = Self.overtimeFill
        } else if stage.phase.isBreak {
            tint = Self.breakTint
            fill = Self.breakFill
        } else {
            tint = Self.focusTint
            fill = Self.focusFill
        }
    }
}

// MARK: - Components

/// The only part of the popover that follows the seconds.
struct TimerDial: View {
    var model: AppModel
    var tint: Color
    var isDimmed: Bool
    var diameter: CGFloat
    var caption: String

    var body: some View {
        let snapshot = model.snapshot
        let isIdle = snapshot.phase == .idle
        TimerRing(
            progress: isIdle ? 0 : snapshot.progress,
            tint: tint,
            isDimmed: isDimmed,
            diameter: diameter,
            readout: isIdle ? TimerReadout.clock(Int(model.nextFocusDuration)) : TimerReadout(snapshot).text,
            caption: caption
        )
    }
}

struct TimerRing: View {
    var progress: Double
    var tint: Color
    /// Paused: the ring and digits fade so a frozen timer doesn't read as running.
    var isDimmed = false
    var diameter: CGFloat
    var readout: String
    var caption: String

    private var lineWidth: CGFloat { (diameter * 0.055).rounded() }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.opacity(isDimmed ? 0.35 : 1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(readout)
                    .font(.system(size: (diameter * 0.24).rounded(), weight: .regular, design: .rounded))
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .padding(.horizontal, lineWidth + 12)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
    }
}

/// One dot per focus in the cycle: done ones filled, the one under way ringed.
struct RoundDots: View {
    /// Past this many the dots stop being countable at a glance, so they become "3/12".
    static let maxDots = 8

    var cycle: Int
    var stage: AppModel.TimerStage

    private var cycleLength: Int { max(1, cycle) }

    /// A break belongs to the round it follows, so the count only moves when the next focus can start.
    var round: Int {
        let done = stage.completedFocusesInCycle
        let round =
            switch stage.phase {
            case .idle, .focus: done + 1
            case .shortBreak: max(done, 1)
            case .longBreak: cycleLength
            }
        return min(round, cycleLength)
    }

    private var filled: Int {
        switch stage.phase {
        case .idle, .focus: min(stage.completedFocusesInCycle, cycleLength)
        case .shortBreak, .longBreak: round
        }
    }

    var body: some View {
        Group {
            if cycleLength > Self.maxDots {
                Text("\(round)/\(cycleLength)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(0..<cycleLength, id: \.self) { index in
                        Circle()
                            .fill(index < filled ? AnyShapeStyle(PhaseStyle.focusTint) : AnyShapeStyle(.quaternary))
                            .overlay(
                                Circle()
                                    .strokeBorder(PhaseStyle.focusTint, lineWidth: 1.5)
                                    .opacity(stage.phase == .focus && index == filled ? 1 : 0)
                            )
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Round \(round) of \(cycleLength)")
    }
}

/// "on <task> ▾": the current task, switchable at any time, with the block scheduled now
/// offered beneath when nothing is chosen. Reads `model.tasks`, never `model.snapshot`.
struct CurrentTaskLine: View {
    var model: AppModel

    private var tasks: TaskStore { model.tasks }
    private var selected: UUID? { model.selectedTaskID }

    private var suggestion: TaskItem? {
        guard let id = tasks.suggestedTaskID, id != selected, let task = tasks.task(id: id), !task.isDone else { return nil }
        return task
    }

    var body: some View {
        VStack(spacing: 8) {
            // Plain styles, so the label draws the same whatever the state; the system button
            // styles restyle the text differently for an empty and a chosen task.
            Menu {
                menuContent
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: 240)
            .frame(height: 20)
            .help(model.isFocusing ? "Switch the task this focus counts toward" : "Choose a task for the next focus")
            .accessibilityLabel("Current task")
            .accessibilityValue(model.currentTaskTitle ?? "No task")

            if selected == nil, let suggestion {
                Button {
                    model.selectTask(suggestion.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(PopoverStyle.accent)
                        Text("Scheduled now: \(suggestion.title)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(PopoverStyle.accent.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 240)
                .help("Work on “\(suggestion.title)”")
                .accessibilityLabel("Work on \(suggestion.title), scheduled now")
            }
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            if let title = model.currentTaskTitle {
                Text("on")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Choose a task")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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

/// The end-of-phase moment. Calm on purpose: overtime still counts, so nothing here is urgent.
struct DecisionCard: View {
    var prompt: AppModel.EndPrompt
    var model: AppModel
    var style: PhaseStyle

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(prompt == .focusEnded ? "Focus complete. Take a break?" : "Break's over. Ready to focus?")
                    .font(.headline)
                Text(prompt == .focusEnded ? "Overtime still counts toward this session." : "Take a little longer if you need it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            switch prompt {
            case .focusEnded:
                primary("Start break", symbol: "cup.and.saucer.fill", action: model.startBreak)
                HStack(spacing: 8) {
                    secondary("+5 min", symbol: "plus") { model.extend(minutes: 5) }
                    secondary("Keep going", symbol: "arrow.forward", action: model.keepGoing)
                }
            case .breakEnded:
                primary("Start focus", symbol: "play.fill", action: model.startFocus)
                HStack(spacing: 8) {
                    secondary("+2 min", symbol: "plus") { model.extend(minutes: 2) }
                    secondary("Done for now", symbol: "checkmark", action: model.stopAndLog)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(style.tint.opacity(0.10)))
    }

    private func primary(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(PillButtonStyle(fill: style.fill))
    }

    private func secondary(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(SoftButtonStyle())
    }
}

struct PresetRow: View {
    var model: AppModel
    var tint: Color

    @State private var custom = ""
    @State private var isInvalid = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.settings.presets.prefix(3)) { preset in
                let isDefault = preset.id == model.settings.defaultPresetID
                Chip(
                    title: Self.shortSummary(preset.profile),
                    emphasis: model.pendingOneOff == .preset(preset.id) ? .selected : isDefault ? .outlined : .none,
                    tint: tint
                ) {
                    model.toggleOneOffPreset(preset.id)
                }
                .help(isDefault ? "\(preset.displayName), the default" : "\(preset.displayName) for the next focus only")
            }
            Spacer(minLength: 0)
            // A queued preset shows as its filled chip; only a typed one-off, which has no chip, gets a pill.
            if case .custom(let override) = model.pendingOneOff {
                Chip(title: "\(Self.summary(override)) once", symbol: "xmark", emphasis: .selected, tint: tint) {
                    model.clearOneOff()
                }
                .help("For the next focus and its break only. Click to clear.")
            } else {
                TextField("Custom", text: $custom)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    // AppKit sizes the field itself, and now and then a point taller; the popover
                    // takes its content's height, so that point moved the whole layout (#38).
                    .frame(width: 56, height: 16)
                    .padding(.horizontal, 8)
                    .frame(height: Chip.height)
                    .background(Capsule().fill(PopoverStyle.surface))
                    .overlay(Capsule().strokeBorder(Color(nsColor: .systemRed), lineWidth: isInvalid ? 1 : 0))
                    .help("Next focus only: minutes, or focus/break like 50/10")
                    .onSubmit {
                        isInvalid = !model.applyOverride(custom)
                        if !isInvalid { custom = "" }
                    }
                    .onChange(of: custom) { isInvalid = false }
            }
        }
        .font(.callout)
    }

    /// "25/5": focus and short break, in minutes.
    static func shortSummary(_ profile: TimerProfile) -> String {
        "\(Int((profile.focusDuration / 60).rounded()))/\(Int((profile.shortBreakDuration / 60).rounded()))"
    }

    static func summary(_ override: SessionOverride) -> String {
        let focus = override.focus.map { "\(Int(($0 / 60).rounded()))" } ?? "–"
        return override.breakDuration.map { "\(focus)/\(Int(($0 / 60).rounded()))" } ?? focus
    }
}

struct Chip: View {
    static let height: CGFloat = 26

    enum Emphasis {
        case none
        /// The default preset: outlined, so it stays distinguishable from a pending one-off.
        case outlined
        /// A pending one-off, the only emphasis with a tinted fill.
        case selected
    }

    var title: String
    var symbol: String?
    var emphasis: Emphasis
    var tint: Color
    var action: @MainActor () -> Void

    private var isSelected: Bool { emphasis == .selected }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).monospacedDigit()
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .foregroundStyle(isSelected ? tint : .primary)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(PopoverStyle.surface)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.6), lineWidth: emphasis == .outlined ? 1 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
