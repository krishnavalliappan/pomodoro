import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
@testable import Pomodoro

enum Snapshot {
    /// References live in the repo-level `Snapshots/` folder rather than SnapshotTesting's
    /// default `__Snapshots__`, so CI can upload a single directory for visual QA.
    static func directory(for file: StaticString) -> String {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent() // PomodoroTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Snapshots", isDirectory: true)
            .path
    }

    /// Renders `view` in light and dark, as `<name>.<variant>.light.png` and `….dark.png`.
    /// Without a `size`, the view is content-sized: it takes the height it fits, as the popover does.
    @MainActor
    static func assertLightAndDark(
        _ view: some View,
        size: CGSize? = nil,
        name: String,
        variant: String? = nil,
        inWindow: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let appearances: [(NSAppearance.Name, ColorScheme, String)] = [
            (.aqua, .light, "light"),
            (.darkAqua, .dark, "dark"),
        ]
        for (appearance, scheme, label) in appearances {
            let host = makeHost(view, appearance: appearance, scheme: scheme, size: size)
            // A `List` is a table view, whose rows only exist once it's in a window.
            var window: NSWindow?
            if inWindow {
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.appearance = host.appearance
                w.contentView = host
                window = w
            }
            host.layoutSubtreeIfNeeded()
            if inWindow {
                RunLoop.main.run(until: Date() + 0.2)
                host.layoutSubtreeIfNeeded()
            }
            defer { window?.contentView = nil }

            let failure = verifySnapshot(
                of: host,
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: [variant, label].compactMap { $0 }.joined(separator: "."),
                snapshotDirectory: directory(for: file),
                file: file,
                testName: name,
                line: line
            )
            if let failure {
                XCTFail(failure, file: file, line: line)
            }
        }
    }

    @MainActor
    static func makeHost(_ view: some View, appearance: NSAppearance.Name, scheme: ColorScheme, size: CGSize?) -> NSView {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: appearance)
        // Content-sized hosts measure themselves, in their own appearance, so the frame is what they lay out.
        host.frame = CGRect(origin: .zero, size: size ?? PopoverView.integralSize(host.fittingSize))
        return host
    }

    /// The pixel size `assertLightAndDark` writes for `view` when it's content-sized.
    @MainActor
    static func renderedPixelSize(_ view: some View, appearance: NSAppearance.Name, scheme: ColorScheme) -> CGSize {
        let host = makeHost(view, appearance: appearance, scheme: scheme, size: nil)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return .zero }
        host.cacheDisplay(in: host.bounds, to: rep)
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}
