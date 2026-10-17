import AppKit
import PomodoroCore
import SwiftUI

/// What the popover's chrome buttons do, injected so snapshots don't open windows or quit.
struct PopoverActions {
    var openPlanner: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
}

/// Sized to its content: the task list grows to at most five rows or folds away, so the popover
/// is only as tall as what it shows.
struct PopoverView: View {
    static let width: CGFloat = 320

    /// Whole points, so the popover and its snapshots agree on one height on any display scale.
    static func integralSize(_ fitting: CGSize) -> CGSize {
        CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
    }

    let model: AppModel
    var actions = PopoverActions()
    /// Pre-filled quick-add text, for snapshots of the preview.
    var quickAddText = ""
    /// Where the Today list remembers whether it's folded; injected so tests don't share state.
    var defaults: UserDefaults

    /// Space types into the quick-add field rather than toggling the timer.
    @State private var isEditingTask = false

    init(model: AppModel, actions: PopoverActions = PopoverActions(), quickAddText: String = "", defaults: UserDefaults = .standard) {
        self.model = model
        self.actions = actions
        self.quickAddText = quickAddText
        self.defaults = defaults
    }

    private var snapshot: TimerSnapshot { model.snapshot }
    private var style: PhaseStyle { PhaseStyle(snapshot) }
    /// Chips set up the next focus, so they only show before one: not during a focus or break.
    private var showsPlanning: Bool { snapshot.phase == .idle }
    private var isPaused: Bool { snapshot.status == .paused }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 6)
            TimerRing(
                progress: snapshot.phase == .idle ? 0 : snapshot.progress,
                tint: style.tint,
                isDimmed: isPaused,
                diameter: model.prompt == nil ? 148 : 104,
                readout: readout,
                caption: caption
            )
            Spacer(minLength: 8)
            if let prompt = model.prompt {
                DecisionCard(prompt: prompt, model: model, style: style)
            } else {
                controls
            }
            Spacer(minLength: 8)
            if showsPlanning {
                PresetRow(model: model, tint: PhaseStyle.focusTint)
                Spacer(minLength: 8)
            }
            TaskPickerLine(model: model)
            Spacer(minLength: 6)
            Divider()
            PopoverTaskSection(
                model: model, openPlanner: actions.openPlanner, quickAddText: quickAddText, isEditing: $isEditingTask,
                defaults: defaults)
                .equatable()
                .padding(.vertical, 8)
            Divider()
            footer
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(shortcuts)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(style.title, systemImage: style.symbol)
                .font(.headline)
                .foregroundStyle(style.tint)
            if isPaused {
                Image(systemName: "pause.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Paused")
            }
            Spacer()
            Text(roundText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var readout: String {
        snapshot.phase == .idle
            ? TimerReadout.clock(Int(model.nextFocusDuration))
            : TimerReadout(snapshot).text
    }

    private var caption: String {
        if snapshot.phase == .idle { return "Ready" }
        switch snapshot.status {
        case .paused: return "Paused"
        case .overtime: return "Overtime"
        case .awaitingDecision: return "Time's up"
        case .running: return snapshot.phase == .focus ? "Until break" : "Until focus"
        }
    }

    /// A break belongs to the round it follows, so the number only moves when the next focus can start.
    private var roundText: String {
        let cycle = model.longBreakEvery
        let done = snapshot.completedFocusesInCycle
        let round =
            switch snapshot.phase {
            case .idle, .focus: done + 1
            case .shortBreak: max(done, 1)
            case .longBreak: cycle
            }
        return "Round \(min(round, cycle)) of \(cycle)"
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            primaryControl
            if snapshot.phase != .idle {
                secondaryControls
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var primaryControl: some View {
        switch (snapshot.phase, snapshot.status) {
        case (.idle, _):
            ProminentButton(title: "Start focus", symbol: "play.fill", fill: style.fill, action: model.startFocus)
        case (_, .paused):
            ProminentButton(title: "Resume", symbol: "play.fill", fill: style.fill, action: model.resume)
        case (.focus, .overtime):
            // Kept going past the prompt: the break is still the natural next step.
            ProminentButton(title: "Start break", symbol: "cup.and.saucer.fill", fill: style.fill, action: model.startBreak)
        case (_, .overtime):
            ProminentButton(title: "Start focus", symbol: "play.fill", fill: style.fill, action: model.startFocus)
        default:
            ProminentButton(title: "Pause", symbol: "pause.fill", fill: style.fill, action: model.pause)
        }
    }

    @ViewBuilder
    private var secondaryControls: some View {
        if case .overtime = snapshot.status {
            IconButton(symbol: "pause.fill", help: "Pause", action: model.pause)
        } else {
            IconButton(text: "+5", help: "Add 5 minutes") { model.extend(minutes: 5) }
            IconButton(symbol: "forward.end.fill", help: snapshot.phase == .focus ? "Skip to break" : "Skip to focus", action: model.skip)
        }
        IconButton(symbol: "stop.fill", help: snapshot.phase == .focus ? "Stop and log (⌘.)" : "Stop (⌘.)", action: model.stopAndLog)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(action: actions.openPlanner) {
                Label("Open Planner", systemImage: "calendar")
            }
            Button(action: actions.openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button(action: actions.quit) {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Shortcuts that must work whichever buttons are on screen.
    private var shortcuts: some View {
        ZStack {
            Button("Start or pause", action: model.toggle)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isEditingTask)
            Button("Stop", action: model.stopAndLog)
                .keyboardShortcut(".", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
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
    var symbol: String
    var tint: Color
    var fill: Color

    init(_ snapshot: TimerSnapshot) {
        let overtime = TimerReadout(snapshot).isOvertime
        let (title, symbol) =
            switch snapshot.phase {
            case .idle: ("Ready to focus", "timer")
            case .focus: ("Focus", "brain.head.profile")
            case .shortBreak: ("Short break", "cup.and.saucer.fill")
            case .longBreak: ("Long break", "sofa.fill")
            }
        self.title = title
        self.symbol = symbol
        if overtime {
            tint = Self.overtimeTint
            fill = Self.overtimeFill
        } else if snapshot.phase.isBreak {
            tint = Self.breakTint
            fill = Self.breakFill
        } else {
            tint = Self.focusTint
            fill = Self.focusFill
        }
    }
}

// MARK: - Components

struct TimerRing: View {
    var progress: Double
    var tint: Color
    /// Paused: the ring and digits fade so a frozen timer doesn't read as running.
    var isDimmed = false
    var diameter: CGFloat
    var readout: String
    var caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.opacity(isDimmed ? 0.35 : 1), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(readout)
                    .font(.system(size: diameter * 0.24, weight: .light, design: .rounded))
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .combine)
    }
}

struct ProminentButton: View {
    var title: String
    var symbol: String
    /// One of `PhaseStyle`'s fills, dark enough for the white label.
    var fill: Color
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(fill)
    }
}

struct IconButton: View {
    var symbol: String?
    var text: String?
    var help: String
    var action: @MainActor () -> Void

    init(symbol: String, help: String, action: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    init(text: String, help: String, action: @escaping @MainActor () -> Void) {
        self.text = text
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else if let text {
                    Text(text).monospacedDigit()
                }
            }
            .frame(width: 22)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The end-of-phase moment. Calm on purpose: overtime still counts, so nothing here is urgent.
struct DecisionCard: View {
    var prompt: AppModel.EndPrompt
    var model: AppModel
    var style: PhaseStyle

    private var tint: Color { style.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt == .focusEnded ? "Focus complete. Take a break?" : "Break's over. Ready to focus?")
                    .font(.headline)
                Text(prompt == .focusEnded ? "Overtime still counts toward this session." : "Take a little longer if you need it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            switch prompt {
            case .focusEnded:
                ProminentButton(title: "Start break", symbol: "cup.and.saucer.fill", fill: style.fill, action: model.startBreak)
                    .controlSize(.large)
                HStack(spacing: 8) {
                    secondary("+5 min", symbol: "plus") { model.extend(minutes: 5) }
                    secondary("Keep going", symbol: "arrow.forward", action: model.keepGoing)
                }
            case .breakEnded:
                ProminentButton(title: "Start focus", symbol: "play.fill", fill: style.fill, action: model.startFocus)
                    .controlSize(.large)
                HStack(spacing: 8) {
                    secondary("+2 min", symbol: "plus") { model.extend(minutes: 2) }
                    secondary("Done for now", symbol: "checkmark", action: model.stopAndLog)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }

    private func secondary(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
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
                    .textFieldStyle(.roundedBorder)
                    // AppKit sizes the field itself, and now and then a point taller; the popover
                    // takes its content's height, so that point moved the whole layout (#38).
                    .frame(width: 76, height: 23)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(nsColor: .systemRed), lineWidth: isInvalid ? 1 : 0)
                    )
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
    enum Emphasis {
        case none
        /// The default preset: outlined, so it stays distinguishable from a pending one-off.
        case outlined
        /// A pending one-off, the only emphasis with a fill.
        case selected
    }

    var title: String
    var symbol: String?
    var emphasis: Emphasis
    var tint: Color
    var action: @MainActor () -> Void

    private var isSelected: Bool { emphasis == .selected }

    private var border: AnyShapeStyle {
        switch emphasis {
        case .none: AnyShapeStyle(.tertiary)
        case .outlined: AnyShapeStyle(tint.opacity(0.8))
        case .selected: AnyShapeStyle(tint.opacity(0.5))
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).monospacedDigit()
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? tint : .primary)
            .background(Capsule().fill(isSelected ? tint.opacity(0.16) : .clear))
            .overlay(Capsule().strokeBorder(border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Today's dots, focus time, count and streak on one line. Narrower variants drop the label,
/// then shorten the streak, then drop the dots, so the row never wraps or grows taller.
struct TodayRow: View {
    static let maxDots = 12

    var summary: TodaySummary
    var cycle: Int

    private var completed: Int { summary.completedPomodoros }

    /// Whole cycles, so the empty dots show how far the current one has to go.
    private var dotCount: Int {
        let cycle = max(1, cycle)
        return min(Self.maxDots, (completed / cycle + 1) * cycle)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(showsLabel: true, showsDots: true, isLong: true)
            line(showsLabel: false, showsDots: true, isLong: true)
            line(showsLabel: false, showsDots: true, isLong: false)
            line(showsLabel: false, showsDots: false, isLong: false)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(summary))
    }

    private func line(showsLabel: Bool, showsDots: Bool, isLong: Bool) -> some View {
        HStack(spacing: 8) {
            if showsLabel {
                Text("Today")
                    .foregroundStyle(.secondary)
            }
            if showsDots {
                dots
            }
            Spacer(minLength: 8)
            Text(Self.text(summary, isLong: isLong))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var dots: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                ForEach(0..<dotCount, id: \.self) { index in
                    Circle()
                        .fill(index < completed ? AnyShapeStyle(PhaseStyle.focusTint) : AnyShapeStyle(.quaternary))
                        .frame(width: 8, height: 8)
                }
            }
            if completed > Self.maxDots {
                Text("+\(completed - Self.maxDots)")
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    /// "1h 40m · 4 🍅 · 🔥 6-day streak", or "1h 40m · 4 🍅 · 🔥 6" when short.
    static func text(_ summary: TodaySummary, isLong: Bool = true) -> String {
        let hasFocus = summary.focusedSeconds > 0 || summary.completedPomodoros > 0
        var parts: [String] =
            hasFocus
            ? [Stats.durationText(summary.focusedSeconds), "\(summary.completedPomodoros) 🍅"]
            : [isLong ? "No focus yet" : "0m"]
        let streak = summary.streak.current
        if streak > 0 {
            parts.append(isLong ? "🔥 \(streak)-day streak" : "🔥 \(streak)")
        }
        return parts.joined(separator: " · ")
    }

    static func accessibilityText(_ summary: TodaySummary) -> String {
        let count = summary.completedPomodoros
        var text = "Today: \(Stats.durationText(summary.focusedSeconds)) of focus, \(count == 1 ? "1 pomodoro" : "\(count) pomodoros")"
        if summary.streak.current > 0 { text += ", \(summary.streak.current)-day streak" }
        return text
    }
}
