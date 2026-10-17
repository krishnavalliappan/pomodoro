import AppKit
import PomodoroCore
import SwiftUI

/// What the popover's chrome buttons do, injected so snapshots don't open windows or quit.
struct PopoverActions {
    var openPlanner: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
}

struct PopoverView: View {
    static let size = CGSize(width: 320, height: 420)

    let model: AppModel
    var actions = PopoverActions()

    private var snapshot: TimerSnapshot { model.snapshot }
    private var style: PhaseStyle { PhaseStyle(snapshot) }
    /// Chips set up the next focus, so they only show before one: not during a focus or break.
    private var showsPlanning: Bool { snapshot.phase == .idle }
    private var isPaused: Bool { snapshot.status == .paused }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 8)
            TimerRing(
                progress: snapshot.phase == .idle ? 0 : snapshot.progress,
                tint: style.tint,
                isDimmed: isPaused,
                diameter: model.prompt == nil ? 168 : 116,
                readout: readout,
                caption: caption
            )
            Spacer(minLength: 10)
            if let prompt = model.prompt {
                DecisionCard(prompt: prompt, model: model, style: style)
            } else {
                controls
            }
            Spacer(minLength: 10)
            if showsPlanning {
                PresetRow(model: model, tint: PhaseStyle.focusTint)
                Spacer(minLength: 10)
            }
            taskLine
            Spacer(minLength: 8)
            TodayRow(completed: model.completedToday, cycle: model.longBreakEvery)
            Spacer(minLength: 10)
            Divider()
            footer
                .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: Self.size.width, height: Self.size.height)
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

    private var roundText: String {
        let cycle = model.longBreakEvery
        let done = snapshot.completedFocusesInCycle
        switch snapshot.phase {
        case .idle, .focus: return "Round \(min(done + 1, cycle)) of \(cycle)"
        case .shortBreak: return "\(min(done, cycle)) of \(cycle) done"
        case .longBreak: return "Cycle done"
        }
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

    private var taskLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
            Text(model.currentTaskTitle ?? "No task selected")
                .foregroundStyle(model.currentTaskTitle == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.callout)
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
        switch snapshot.phase {
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
            if let pill = pillTitle {
                Chip(title: "\(pill) once", symbol: "xmark", emphasis: .selected, tint: tint) {
                    model.clearOneOff()
                }
                .help("For the next focus and its break only. Click to clear.")
            } else {
                TextField("Custom", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
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

    private var pillTitle: String? {
        switch model.pendingOneOff {
        case .custom(let override): Self.summary(override)
        case .preset: model.pendingOneOffProfile.map(Self.shortSummary)
        case nil: nil
        }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? tint : .primary)
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(tint.opacity(0.16)) : AnyShapeStyle(.quaternary))
            )
            .overlay(Capsule().strokeBorder(emphasis == .none ? .clear : tint.opacity(isSelected ? 0.5 : 0.8)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TodayRow: View {
    static let maxDots = 12

    var completed: Int
    var cycle: Int

    /// Whole cycles, so the empty dots show how far the current one has to go.
    private var dotCount: Int {
        let cycle = max(1, cycle)
        return min(Self.maxDots, (completed / cycle + 1) * cycle)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Today")
                .foregroundStyle(.secondary)
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
            }
            Spacer(minLength: 0)
            Text(completed == 1 ? "1 pomodoro" : "\(completed) pomodoros")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
