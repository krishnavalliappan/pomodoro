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
    /// Chips set up the next focus, so they only show when one isn't in progress.
    private var showsPlanning: Bool { model.prompt == nil && snapshot.phase != .focus }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 8)
            TimerRing(
                progress: snapshot.phase == .idle ? 0 : snapshot.progress,
                tint: style.tint,
                diameter: model.prompt == nil ? 168 : 116,
                readout: readout,
                caption: caption
            )
            Spacer(minLength: 10)
            if let prompt = model.prompt {
                DecisionCard(prompt: prompt, model: model, tint: style.tint)
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
            ProminentButton(title: "Start focus", symbol: "play.fill", tint: style.tint, action: model.startFocus)
        case (_, .paused):
            ProminentButton(title: "Resume", symbol: "play.fill", tint: style.tint, action: model.resume)
        case (.focus, .overtime):
            // Kept going past the prompt: the break is still the natural next step.
            ProminentButton(title: "Start break", symbol: "cup.and.saucer.fill", tint: style.tint, action: model.startBreak)
        case (_, .overtime):
            ProminentButton(title: "Start focus", symbol: "play.fill", tint: style.tint, action: model.startFocus)
        default:
            ProminentButton(title: "Pause", symbol: "pause.fill", tint: style.tint, action: model.pause)
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
        IconButton(symbol: "stop.fill", help: snapshot.phase == .focus ? "Stop and log (⌘.)" : "Stop (⌘.)", action: model.stop)
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
            Button("Stop", action: model.stop)
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

    var title: String
    var symbol: String
    var tint: Color

    init(_ snapshot: TimerSnapshot) {
        let overtime = TimerReadout(snapshot).isOvertime
        switch snapshot.phase {
        case .idle:
            self.init(title: "Ready to focus", symbol: "timer", tint: Self.focusTint)
        case .focus:
            self.init(title: "Focus", symbol: "brain.head.profile", tint: overtime ? Self.overtimeTint : Self.focusTint)
        case .shortBreak:
            self.init(title: "Short break", symbol: "cup.and.saucer.fill", tint: overtime ? Self.overtimeTint : Self.breakTint)
        case .longBreak:
            self.init(title: "Long break", symbol: "sofa.fill", tint: overtime ? Self.overtimeTint : Self.breakTint)
        }
    }

    init(title: String, symbol: String, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }
}

// MARK: - Components

struct TimerRing: View {
    var progress: Double
    var tint: Color
    var diameter: CGFloat
    var readout: String
    var caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text(readout)
                    .font(.system(size: diameter * 0.24, weight: .light, design: .rounded))
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
    var tint: Color
    var action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
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
    var tint: Color

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
                ProminentButton(title: "Start break", symbol: "cup.and.saucer.fill", tint: tint, action: model.startBreak)
                    .controlSize(.large)
                HStack(spacing: 8) {
                    secondary("+5 min", symbol: "plus") { model.extend(minutes: 5) }
                    secondary("Keep going", symbol: "arrow.forward", action: model.keepGoing)
                }
            case .breakEnded:
                ProminentButton(title: "Start focus", symbol: "play.fill", tint: tint, action: model.startFocus)
                    .controlSize(.large)
                HStack(spacing: 8) {
                    secondary("+2 min", symbol: "plus") { model.extend(minutes: 2) }
                    secondary("Done for now", symbol: "checkmark", action: model.stop)
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
                Chip(
                    title: Self.shortSummary(preset.profile),
                    isSelected: model.pendingOverride == nil && preset.id == model.settings.defaultPresetID,
                    tint: tint
                ) {
                    model.selectPreset(preset.id)
                }
                .help(preset.displayName)
            }
            Spacer(minLength: 0)
            if let override = model.pendingOverride {
                Chip(title: "\(Self.summary(override)) once", symbol: "xmark", isSelected: true, tint: tint) {
                    model.clearOverride()
                }
                .help("One-off override for the next focus. Click to clear.")
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
    var title: String
    var symbol: String?
    var isSelected: Bool
    var tint: Color
    var action: @MainActor () -> Void

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
            .overlay(Capsule().strokeBorder(isSelected ? tint.opacity(0.5) : .clear))
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
