import AppKit
import PomodoroCore
import SnapshotTesting
import SwiftUI
import XCTest
@testable import Pomodoro

@MainActor
final class StatusItemIconTests: XCTestCase {
    func testIconFollowsPhase() throws {
        let h = try ModelHarness(display: .iconOnly)
        let model = h.makeModel()
        XCTAssertEqual(MenuBarController.icon(for: model.snapshot), .tomato)
        model.startFocus()
        XCTAssertEqual(MenuBarController.icon(for: model.snapshot), .tomato)
        model.pause()
        XCTAssertEqual(MenuBarController.icon(for: model.snapshot), .symbol("pause.circle"))
    }

    func testGlyphTitleReplacesLeadingEmoji() {
        XCTAssertEqual(MenuBarController.glyphTitle("🍅 18:42").icon, .tomato)
        XCTAssertEqual(MenuBarController.glyphTitle("🍅 18:42").text, "18:42")
        XCTAssertEqual(MenuBarController.glyphTitle("☕ 03:10").icon, .symbol("cup.and.saucer.fill"))
        XCTAssertEqual(MenuBarController.glyphTitle("☕ 03:10").text, "03:10")
        XCTAssertNil(MenuBarController.glyphTitle("+02:15").icon)
        XCTAssertEqual(MenuBarController.glyphTitle("+02:15").text, "+02:15")
    }

    func testAssetsResolve() throws {
        let glyph = try XCTUnwrap(NSImage(named: "MenuBarIcon"))
        XCTAssertTrue(glyph.isTemplate)
        XCTAssertEqual(glyph.size, CGSize(width: 18, height: 18))
        XCTAssertNotNil(NSImage(named: "AppIcon"))
    }

    func testAppIconSnapshot() throws {
        let icon = try XCTUnwrap(NSImage(named: "AppIcon"))
        let size = CGSize(width: 256, height: 256)
        let host = NSHostingView(rootView: Image(nsImage: icon).resizable().frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        verify(host, testName: "AppIcon", named: "256")
    }

    func testMenuBarSnapshots() {
        let cases: [(String, String?, Bool)] = [
            ("iconOnly", nil, false),
            ("glyphTime", "🍅 18:42", true),
            ("emojiTime", "🍅 18:42", false),
        ]
        let backgrounds: [(String, NSAppearance.Name, NSColor)] = [
            ("light", .aqua, NSColor(white: 0.93, alpha: 1)),
            ("dark", .darkAqua, NSColor(white: 0.17, alpha: 1)),
        ]
        for (variant, title, glyph) in cases {
            for (label, appearance, background) in backgrounds {
                let bar = NSView(frame: CGRect(x: 0, y: 0, width: 96, height: 24))
                bar.appearance = NSAppearance(named: appearance)
                bar.wantsLayer = true
                bar.layer?.backgroundColor = background.cgColor

                let button = NSButton(frame: bar.bounds)
                button.isBordered = false
                MenuBarController.apply(title: title, icon: .tomato, glyphBesideTime: glyph, to: button)
                bar.addSubview(button)
                verify(bar, testName: "StatusItem", named: "\(variant).\(label)")
            }
        }
    }

    private func verify(_ view: NSView, testName: String, named: String, file: StaticString = #filePath, line: UInt = #line) {
        view.layoutSubtreeIfNeeded()
        let failure = verifySnapshot(
            of: view,
            as: .image(precision: 0.99, perceptualPrecision: 0.98),
            named: named,
            snapshotDirectory: Snapshot.directory(for: file),
            file: file,
            testName: testName,
            line: line
        )
        if let failure {
            XCTFail(failure, file: file, line: line)
        }
    }
}
