import PomodoroCore
import SwiftUI

/// What the floating card asks of whoever hosts it.
struct FloatingTimerActions {
    enum Drag { case began, moved, ended }

    var openPopover: @MainActor () -> Void = {}
    var setCollapsed: @MainActor (Bool) -> Void = { _ in }
    var drag: @MainActor (Drag) -> Void = { _ in }
}

/// The card that floats over other windows while a session runs: a tomato in its progress ring,
/// the time, and the controls worth having without opening the popover.
///
/// Like the popover's timer tab, only `FloatingReadout` and `FloatingRing` read the snapshot,
/// so the tick doesn't re-render the rest.
struct FloatingTimerView: View {
    static let cardSize = CGSize(width: 276, height: 118)
    static let collapsedSize = CGSize(width: 92, height: 92)
    /// Room around the card for its shadow, and above it for the hover row.
    static let insets = EdgeInsets(top: 18, leading: 16, bottom: 22, trailing: 16)

    static func panelSize(collapsed: Bool) -> CGSize {
        let card = collapsed ? collapsedSize : cardSize
        return CGSize(width: card.width + insets.leading + insets.trailing, height: card.height + insets.top + insets.bottom)
    }

    var model: AppModel
    var isCollapsed: Bool
    var actions: FloatingTimerActions
    /// The pointer is over the panel, which brings up the hover row. Tracked by the host, since
    /// SwiftUI's own hover tracking stops while another app is active.
    var isHovering = false

    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stage: AppModel.TimerStage { model.stage }
    private var style: PhaseStyle { PhaseStyle(stage) }

    var body: some View {
        Group {
            if isCollapsed { collapsed } else { card }
        }
        .padding(Self.insets)
        .frame(width: Self.panelSize(collapsed: isCollapsed).width, height: Self.panelSize(collapsed: isCollapsed).height)
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        Button { actions.setCollapsed(false) } label: {
            FloatingRing(model: model, tint: style.tint, mood: TomatoMood(stage), diameter: 72)
                .frame(width: Self.collapsedSize.width, height: Self.collapsedSize.height)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        // A plain gesture loses to the button, which would expand on every drag.
        .highPriorityGesture(dragGesture)
        .help("Show the full timer")
        .accessibilityLabel("Expand timer")
    }

    // MARK: - Card

    private var card: some View {
        HStack(spacing: 12) {
            Button(action: actions.openPopover) {
                FloatingRing(model: model, tint: style.tint, mood: TomatoMood(stage), diameter: 72)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open Pomodoro")
            .accessibilityLabel("Open Pomodoro")

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(chipTitle)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(height: 17)
                        .background(Capsule().fill(style.fill))
                    Spacer(minLength: 4)
                    RoundDots(cycle: model.longBreakEvery, stage: stage)
                        .scaleEffect(0.85, anchor: .trailing)
                }
                FloatingReadout(model: model, isDimmed: stage.status == .paused)
                    .padding(.top, 2)
                Text(taskLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    primaryButton
                    if stage.status == .overtime {
                        // Overtime still counts, so an interruption needs a way to freeze it.
                        FloatingButton(symbol: "pause.fill", help: "Pause", action: model.pause)
                    } else if stage.status == .running || stage.status == .paused {
                        FloatingButton(symbol: "forward.end.fill", help: stage.phase == .focus ? "Skip to break" : "Skip to focus", action: model.skip)
                    }
                    FloatingButton(
                        symbol: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        help: model.isMuted ? "Unmute sounds" : "Mute all sounds",
                        isOn: model.isMuted,
                        action: model.toggleMute
                    )
                }
                .padding(.top, 7)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .overlay(alignment: .topTrailing) {
            extras
                .offset(x: -12, y: -13)
                .opacity(isHovering && !isDragging ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        }
        .gesture(dragGesture)
    }

    /// Kept off the main row: handy, but not worth hitting by accident.
    private var extras: some View {
        HStack(spacing: 4) {
            if stage.status != .paused {
                FloatingButton(text: "+5", help: "Add 5 minutes", raised: true) { model.extend(minutes: 5) }
            }
            if stage.phase == .focus, model.openCurrentTask != nil {
                FloatingButton(symbol: "checkmark", help: "Mark the task done", raised: true, action: model.completeCurrentTask)
            }
            FloatingButton(symbol: "stop.fill", help: stage.phase == .focus ? "Stop and log" : "Stop", raised: true, action: model.stopAndLog)
            FloatingButton(symbol: "circle.lefthalf.filled", help: "Shrink to the tomato", raised: true) { actions.setCollapsed(true) }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch (stage.phase, stage.status) {
        case (_, .paused):
            FloatingButton(symbol: "play.fill", help: "Resume", fill: style.fill, action: model.resume)
        case (.focus, .overtime), (.focus, .awaitingDecision):
            FloatingButton(symbol: "cup.and.saucer.fill", help: "Start break", fill: style.fill, action: model.startBreak)
        case (_, .overtime), (_, .awaitingDecision):
            FloatingButton(symbol: "play.fill", help: "Start focus", fill: style.fill, action: model.startFocus)
        default:
            FloatingButton(symbol: "pause.fill", help: "Pause", fill: style.fill, action: model.pause)
        }
    }

    private var chipTitle: String {
        switch stage.status {
        case .paused: "Paused"
        case .overtime: "Overtime"
        case .awaitingDecision: "Time's up"
        case .running: style.title
        }
    }

    private var taskLine: String {
        switch stage.phase {
        case .shortBreak: "Stretch, sip some water"
        case .longBreak: "Step away for a bit"
        case .idle, .focus: model.currentTaskTitle ?? "No task picked"
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in
                if !isDragging {
                    isDragging = true
                    actions.drag(.began)
                } else {
                    actions.drag(.moved)
                }
            }
            .onEnded { _ in
                isDragging = false
                actions.drag(.ended)
            }
    }
}

// MARK: - Ticking parts

/// The time, the one text the tick reaches.
private struct FloatingReadout: View {
    var model: AppModel
    var isDimmed: Bool

    var body: some View {
        Text(TimerReadout(model.snapshot).text)
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isDimmed ? .secondary : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel("Time")
    }
}

/// The progress ring with the tomato inside it.
private struct FloatingRing: View {
    var model: AppModel
    var tint: Color
    var mood: TomatoMood
    var diameter: CGFloat

    var body: some View {
        let snapshot = model.snapshot
        let progress = TimerReadout(snapshot).isOvertime ? 1 : snapshot.progress
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint.opacity(mood == .sleeping ? 0.4 : 1), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            TomatoFace(mood: mood)
                .frame(width: diameter - 22, height: diameter - 22)
        }
        .padding(2.5)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - The tomato

enum TomatoMood: Equatable {
    case focused, resting, sleeping, flustered

    init(_ stage: AppModel.TimerStage) {
        if stage.status == .paused {
            self = .sleeping
        } else if stage.isOvertime || stage.status == .awaitingDecision {
            self = .flustered
        } else if stage.phase.isBreak {
            self = .resting
        } else {
            self = .focused
        }
    }
}

/// Drawn on a 48-point grid and scaled, so it stays crisp at any size.
struct TomatoFace: View {
    var mood: TomatoMood

    private static let skin = Color(red: 1, green: 0.353, blue: 0.306)
    private static let leaf = Color(red: 0.204, green: 0.78, blue: 0.349)
    private static let stem = Color(red: 0.165, green: 0.616, blue: 0.282)
    private static let ink = Color(red: 0.29, green: 0.078, blue: 0.063)
    private static let blush = Color(red: 1, green: 0.604, blue: 0.604)

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 48
            context.scaleBy(x: s, y: s)
            draw(in: &context)
        }
        .overlay(alignment: .topTrailing) { accessory }
    }

    private func draw(in context: inout GraphicsContext) {
        context.fill(Path(ellipseIn: CGRect(x: 7, y: 13, width: 34, height: 30)), with: .color(Self.skin))
        context.fill(Path(ellipseIn: CGRect(x: 13, y: 19, width: 10, height: 6)), with: .color(.white.opacity(0.35)))
        context.fill(Path(roundedRect: CGRect(x: 23, y: 8, width: 2, height: 6), cornerRadius: 1), with: .color(Self.stem))
        context.fill(Self.leafPath, with: .color(Self.leaf))
        for x in [12.4, 30.4] {
            context.fill(Path(ellipseIn: CGRect(x: x, y: 29.5, width: 5.2, height: 3)), with: .color(Self.blush.opacity(0.8)))
        }
        let line = StrokeStyle(lineWidth: 1.6, lineCap: .round)
        switch mood {
        case .focused, .flustered:
            for x in [19.5, 28.5] {
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: 25, width: 4, height: 4)), with: .color(Self.ink))
                context.fill(Path(ellipseIn: CGRect(x: x + 0.1, y: 25.7, width: 1.2, height: 1.2)), with: .color(.white))
            }
        case .sleeping:
            context.stroke(arcs(y: 27, bend: 2), with: .color(Self.ink), style: line)
        case .resting:
            context.stroke(arcs(y: 28, bend: -2.5), with: .color(Self.ink), style: line)
        }
        if mood == .flustered {
            context.fill(Path(ellipseIn: CGRect(x: 22, y: 30.6, width: 4, height: 4.8)), with: .color(Self.ink))
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: 21.5, y: 32))
            smile.addQuadCurve(to: CGPoint(x: 26.5, y: 32), control: CGPoint(x: 24, y: 34.5))
            context.stroke(smile, with: .color(Self.ink), style: line)
        }
    }

    /// Two closed eyes, curving down (asleep) or up (content).
    private func arcs(y: CGFloat, bend: CGFloat) -> Path {
        var path = Path()
        for x in [17.0, 26.0] {
            path.move(to: CGPoint(x: x, y: y))
            path.addQuadCurve(to: CGPoint(x: x + 5, y: y), control: CGPoint(x: x + 2.5, y: y + bend))
        }
        return path
    }

    @ViewBuilder
    private var accessory: some View {
        switch mood {
        case .sleeping:
            Text("z").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.secondary).offset(x: 4, y: -2)
        case .resting:
            Text("☕").font(.system(size: 11)).offset(x: 6, y: -2)
        case .flustered:
            Text("💦").font(.system(size: 10)).offset(x: 6, y: -2)
        case .focused:
            EmptyView()
        }
    }

    private static let leafPath: Path = {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var p = Path()
        p.move(to: pt(24, 14))
        p.addCurve(to: pt(14, 12), control1: pt(21, 10), control2: pt(16, 10))
        p.addCurve(to: pt(20, 15), control1: pt(17, 12), control2: pt(19, 13))
        p.addCurve(to: pt(13, 17), control1: pt(17, 14), control2: pt(14, 15))
        p.addCurve(to: pt(21, 18), control1: pt(16, 16), control2: pt(19, 17))
        p.addCurve(to: pt(27, 18), control1: pt(22, 20), control2: pt(26, 20))
        p.addCurve(to: pt(35, 17), control1: pt(29, 17), control2: pt(32, 16))
        p.addCurve(to: pt(28, 15), control1: pt(34, 15), control2: pt(31, 14))
        p.addCurve(to: pt(34, 12), control1: pt(29, 13), control2: pt(31, 12))
        p.addCurve(to: pt(24, 14), control1: pt(32, 10), control2: pt(27, 10))
        p.closeSubpath()
        return p
    }()
}

// MARK: - Buttons

/// A small round button: filled in the phase colour for the main action, raised for the hover row.
private struct FloatingButton: View {
    var symbol: String?
    var text: String?
    var help: String
    var fill: Color?
    var isOn = false
    var raised = false
    var action: @MainActor () -> Void

    init(symbol: String, help: String, fill: Color? = nil, isOn: Bool = false, raised: Bool = false, action: @escaping @MainActor () -> Void) {
        self.symbol = symbol
        self.help = help
        self.fill = fill
        self.isOn = isOn
        self.raised = raised
        self.action = action
    }

    init(text: String, help: String, raised: Bool = false, action: @escaping @MainActor () -> Void) {
        self.text = text
        self.help = help
        self.raised = raised
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: raised ? 10 : 11, weight: .bold))
                } else if let text {
                    Text(text).font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(fill != nil ? AnyShapeStyle(.white) : isOn ? AnyShapeStyle(PopoverStyle.accent) : AnyShapeStyle(.primary))
            .frame(minWidth: raised ? 24 : 28)
            .padding(.horizontal, text != nil ? 4 : 0)
            .frame(height: raised ? 24 : 28)
            .background(background)
            .contentShape(Capsule())
        }
        .buttonStyle(FloatingPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var background: some View {
        if let fill {
            Capsule().fill(fill)
        } else if raised {
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        } else {
            Capsule().fill(isOn ? AnyShapeStyle(PopoverStyle.accent.opacity(0.15)) : AnyShapeStyle(PopoverStyle.surface))
        }
    }
}

private struct FloatingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
