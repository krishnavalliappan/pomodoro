import AppKit
import PomodoroCore
import SwiftUI

/// What the popover's chrome buttons do, injected so snapshots don't open windows or quit.
struct PopoverActions {
    var openPlanner: @MainActor () -> Void = {}
    var openStats: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
}

/// One tab at a time above a bar of tabs, sized to the tab on show.
///
/// Only the visible tab is built, so hidden ones observe nothing. This body reads the tab and
/// nothing of the model: the 1 Hz tick reaches only the Timer tab's dial.
struct PopoverView: View {
    static let width: CGFloat = 300

    /// Whole points, so the popover and its snapshots agree on one height on any display scale.
    static func integralSize(_ fitting: CGSize) -> CGSize {
        CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
    }

    let model: AppModel
    let navigation: PopoverNavigation
    var actions = PopoverActions()

    var body: some View {
        @Bindable var navigation = navigation
        VStack(spacing: 0) {
            Group {
                switch navigation.tab {
                case .timer:
                    PopoverTimerTab(model: model)
                case .tasks:
                    PopoverTasksTab(
                        model: model,
                        openPlanner: actions.openPlanner,
                        draft: $navigation.quickAddDraft,
                        isEditing: $navigation.isEditingTask
                    )
                case .sounds:
                    PopoverSoundsTab()
                case .stats:
                    PopoverStatsTab(model: model, openStats: actions.openStats)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            PopoverTabBar(navigation: navigation, actions: actions)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(shortcuts)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Shortcuts that must work whichever tab is on screen.
    private var shortcuts: some View {
        ZStack {
            Button("Start or pause", action: model.toggle)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!navigation.spaceTogglesTimer)
            Button("Stop", action: model.stopAndLog)
                .keyboardShortcut(".", modifiers: .command)
            Button("Settings", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit", action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
            // ⌘1–⌘4, as in other Mac apps with tabs.
            ForEach(Array(PopoverTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) { navigation.select(tab) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Tab bar

struct PopoverTabBar: View {
    var navigation: PopoverNavigation
    var actions: PopoverActions

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PopoverTab.allCases) { tab in
                let isSelected = navigation.tab == tab
                Button {
                    navigation.select(tab)
                } label: {
                    TabIcon(symbol: tab.symbol, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            // With no Dock icon or menu bar, this menu is the only visible way to quit.
            Button {
                gearAnchor.popUp(PopoverGearMenu.make(actions))
            } label: {
                TabIcon(symbol: "gearshape.fill", isSelected: false)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .background(MenuAnchorView(anchor: gearAnchor))
            .help("Settings and Quit")
            .accessibilityLabel("Settings and Quit")
        }
        .frame(height: 36)
    }

    @State private var gearAnchor = MenuAnchor()
}

/// The ⚙ menu. An `NSMenu` rather than a SwiftUI `Menu`, which would restyle the tab icon as a
/// pop-up button; built apart from the view so tests can check its items.
enum PopoverGearMenu {
    @MainActor
    static func make(_ actions: PopoverActions) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Settings…", key: ",", action: actions.openSettings))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Pomodoro", key: "q", action: actions.quit))
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = .command
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}

/// Where the ⚙ menu drops from: just below the button's own AppKit view.
@MainActor
final class MenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private struct TabIcon: View {
    var symbol: String
    var isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isSelected ? AnyShapeStyle(PopoverStyle.accent) : AnyShapeStyle(.secondary))
            .frame(width: 44, height: 30)
            .background(Capsule().fill(isSelected ? PopoverStyle.accent.opacity(0.14) : .clear))
            .contentShape(Capsule())
    }
}

// MARK: - Shared styling

/// Session's look: soft surfaces instead of dividers and borders, round controls, a rose accent.
enum PopoverStyle {
    static let accent = Color(red: 0xE0 / 255, green: 0x5A / 255, blue: 0x78 / 255)
    static let surface = Color.primary.opacity(0.06)
    static let pressedSurface = Color.primary.opacity(0.12)
}

/// The one prominent action: a full-width capsule in a phase fill.
struct PillButtonStyle: ButtonStyle {
    /// One of `PhaseStyle`'s fills, dark enough for the white label.
    var fill: Color
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// Secondary actions: a soft capsule with no border.
struct SoftButtonStyle: ButtonStyle {
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(configuration.isPressed ? PopoverStyle.pressedSurface : PopoverStyle.surface))
            .contentShape(Capsule())
    }
}

/// Small round ghost buttons beside the pill.
struct GhostCircleButton: View {
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
        }
        .buttonStyle(GhostCircleStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct GhostCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(configuration.isPressed ? PopoverStyle.pressedSurface : PopoverStyle.surface))
            .contentShape(Circle())
    }
}
