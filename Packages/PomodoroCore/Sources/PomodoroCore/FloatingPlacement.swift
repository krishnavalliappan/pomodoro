import Foundation

/// Where the floating timer sits on screen.
///
/// Rects are in AppKit's global coordinates (y up), and screens are their visible frames, without
/// the menu bar and Dock. The first screen is the main one.
public enum FloatingPlacement {
    /// The gap kept from a screen edge the window is docked against.
    public static let margin: CGFloat = 8
    /// Dropped this close to an edge, past the margin, the window docks against it.
    public static let snapDistance: CGFloat = 28

    /// The first spot: the main screen's top-right corner, under the menu bar.
    public static func defaultFrame(size: CGSize, screens: [CGRect]) -> CGRect {
        guard let main = screens.first else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: main.maxX - margin - size.width, y: main.maxY - margin - size.height, width: size.width, height: size.height)
    }

    /// Where a dropped window settles: wholly on the screen it mostly covers, and docked against
    /// any edge it was dropped near.
    public static func settled(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard let screen = screen(for: frame, in: screens) else { return frame }
        var frame = clamped(frame, to: screen)
        if frame.minX - screen.minX < margin + snapDistance { frame.origin.x = screen.minX + margin }
        if screen.maxX - frame.maxX < margin + snapDistance { frame.origin.x = screen.maxX - margin - frame.width }
        if frame.minY - screen.minY < margin + snapDistance { frame.origin.y = screen.minY + margin }
        if screen.maxY - frame.maxY < margin + snapDistance { frame.origin.y = screen.maxY - margin - frame.height }
        return clamped(frame, to: screen)
    }

    /// A remembered spot, if a connected screen still shows it; otherwise the default.
    public static func restored(origin: CGPoint?, size: CGSize, screens: [CGRect]) -> CGRect {
        guard let origin else { return defaultFrame(size: size, screens: screens) }
        let frame = CGRect(origin: origin, size: size)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard screens.contains(where: { $0.contains(center) }) else { return defaultFrame(size: size, screens: screens) }
        return settled(frame, screens: screens)
    }

    /// The window at a new size, with the corner nearest its screen's edges held still, so a card
    /// docked top-right stays there as it shrinks or grows.
    public static func resized(_ frame: CGRect, to size: CGSize, screens: [CGRect]) -> CGRect {
        guard let screen = screen(for: frame, in: screens) else { return CGRect(origin: frame.origin, size: size) }
        let x = frame.midX > screen.midX ? frame.maxX - size.width : frame.minX
        let y = frame.midY > screen.midY ? frame.maxY - size.height : frame.minY
        return settled(CGRect(x: x, y: y, width: size.width, height: size.height), screens: screens)
    }

    /// The screen showing most of `frame`, or the one nearest to it when none does.
    static func screen(for frame: CGRect, in screens: [CGRect]) -> CGRect? {
        let covered = screens.map { screen -> CGFloat in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = covered.indices.max(by: { covered[$0] < covered[$1] }), covered[best] > 0 {
            return screens[best]
        }
        return screens.min { distance(from: $0, to: frame) < distance(from: $1, to: frame) }
    }

    private static func distance(from screen: CGRect, to frame: CGRect) -> CGFloat {
        hypot(screen.midX - frame.midX, screen.midY - frame.midY)
    }

    private static func clamped(_ frame: CGRect, to screen: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        return frame
    }
}
