import AppKit
import Observation
import PomodoroCore
import SwiftUI

/// Owns the floating card's panel: shows it while a session runs, moves it as it's dragged,
/// docks it near edges, and remembers where it was left.
@MainActor
final class FloatingTimerController {
    static let originKey = "floatingTimerOrigin"
    static let collapsedKey = "floatingTimerCollapsed"

    /// What the card reads that isn't the model's.
    @MainActor
    @Observable
    final class State {
        var isCollapsed: Bool
        var isHovering = false

        init(isCollapsed: Bool) {
            self.isCollapsed = isCollapsed
        }
    }

    let state: State
    private let model: AppModel
    private let defaults: UserDefaults
    private let screens: @MainActor () -> [CGRect]
    private let mouseLocation: @MainActor () -> CGPoint
    private let openPopover: @MainActor () -> Void
    private(set) var panel: NSPanel?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var screenObserver: (any NSObjectProtocol)?

    init(
        model: AppModel,
        defaults: UserDefaults = .standard,
        screens: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        openPopover: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.defaults = defaults
        self.screens = screens
        self.mouseLocation = mouseLocation
        self.openPopover = openPopover
        state = State(isCollapsed: defaults.bool(forKey: Self.collapsedKey))
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        observe()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel?.orderOut(nil)
    }

    private func observe() {
        let shows = withObservationTracking {
            model.showsFloatingTimer
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        shows ? show() : hide()
    }

    private func show() {
        guard !isVisible else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(FloatingPlacement.restored(origin: savedOrigin, size: currentSize, screens: screens()), display: false)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
        state.isHovering = false
    }

    private func makePanel() -> NSPanel {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: currentSize))
        let actions = FloatingTimerActions(
            openPopover: { [weak self] in self?.openPopover() },
            setCollapsed: { [weak self] in self?.setCollapsed($0) },
            drag: { [weak self] in self?.drag($0) }
        )
        panel.contentView = FloatingHostingView(rootView: FloatingTimerRoot(model: model, state: state, actions: actions), state: state)
        return panel
    }

    // MARK: - Moving

    private var currentSize: CGSize { FloatingTimerView.panelSize(collapsed: state.isCollapsed) }

    func drag(_ phase: FloatingTimerActions.Drag) {
        guard let panel else { return }
        switch phase {
        case .began:
            dragStart = (mouseLocation(), panel.frame.origin)
        case .moved:
            guard let dragStart else { return }
            let mouse = mouseLocation()
            panel.setFrameOrigin(CGPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x, y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
        case .ended:
            dragStart = nil
            place(FloatingPlacement.settled(panel.frame, screens: screens()), animate: true)
        }
    }

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != state.isCollapsed else { return }
        state.isCollapsed = collapsed
        defaults.set(collapsed, forKey: Self.collapsedKey)
        guard let panel else { return }
        place(FloatingPlacement.resized(panel.frame, to: currentSize, screens: screens()), animate: false)
    }

    private func screensChanged() {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(FloatingPlacement.restored(origin: panel.frame.origin, size: currentSize, screens: screens()), display: true)
    }

    private func place(_ frame: CGRect, animate: Bool) {
        panel?.setFrame(frame, display: true, animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        defaults.set([frame.minX, frame.minY], forKey: Self.originKey)
    }

    private var savedOrigin: CGPoint? {
        guard let values = defaults.array(forKey: Self.originKey) as? [Double], values.count == 2 else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
}

/// Floats over everything, on every Space and over full-screen apps, and never takes focus
/// from the app being typed in.
private final class FloatingPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Moved by the card's own drag, so a press on a button never nudges it.
        isMovable = false
        setAccessibilityLabel("Pomodoro timer")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click, since the panel is never key, and tracks the pointer even while
/// another app is active, which SwiftUI's own hover tracking doesn't.
private final class FloatingHostingView: NSHostingView<FloatingTimerRoot> {
    private let state: FloatingTimerController.State

    init(rootView: FloatingTimerRoot, state: FloatingTimerController.State) {
        self.state = state
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor @preconcurrency required init(rootView: FloatingTimerRoot) {
        fatalError("init(rootView:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        state.isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        state.isHovering = false
    }
}

/// Reads the controller's state, so collapsing and hovering re-render the card.
struct FloatingTimerRoot: View {
    var model: AppModel
    var state: FloatingTimerController.State
    var actions: FloatingTimerActions

    var body: some View {
        FloatingTimerView(model: model, isCollapsed: state.isCollapsed, actions: actions, isHovering: state.isHovering)
    }
}
