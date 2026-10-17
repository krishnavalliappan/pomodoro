import Foundation
import Testing
@testable import PomodoroCore

struct FloatingPlacementTests {
    /// A 1440×875 main screen under a 25pt menu bar, and a second one to its right.
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let side = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
    let size = CGSize(width: 300, height: 120)
    let margin = FloatingPlacement.margin

    @Test func startsTopRightOfTheMainScreen() {
        let frame = FloatingPlacement.defaultFrame(size: size, screens: [main, side])
        #expect(frame == CGRect(x: 1440 - margin - 300, y: 875 - margin - 120, width: 300, height: 120))
    }

    @Test func staysWhereItIsDroppedAwayFromTheEdges() {
        let frame = CGRect(x: 500, y: 400, width: 300, height: 120)
        #expect(FloatingPlacement.settled(frame, screens: [main]) == frame)
    }

    @Test func docksAgainstANearbyEdgeOrCorner() {
        let nearLeft = CGRect(x: 20, y: 400, width: 300, height: 120)
        #expect(FloatingPlacement.settled(nearLeft, screens: [main]).origin == CGPoint(x: margin, y: 400))

        let nearBottomRight = CGRect(x: 1440 - 300 - 15, y: 3, width: 300, height: 120)
        #expect(FloatingPlacement.settled(nearBottomRight, screens: [main]).origin == CGPoint(x: 1440 - margin - 300, y: margin))
    }

    @Test func comesBackOnScreenWhenDroppedPartlyOff() {
        let hanging = CGRect(x: -150, y: 820, width: 300, height: 120)
        #expect(FloatingPlacement.settled(hanging, screens: [main]).origin == CGPoint(x: margin, y: 875 - margin - 120))
    }

    @Test func settlesOnTheScreenItMostlyCovers() {
        let straddling = CGRect(x: 1400, y: 300, width: 300, height: 120)
        #expect(FloatingPlacement.settled(straddling, screens: [main, side]).minX == 1440 + margin)
    }

    @Test func restoresARememberedSpot() {
        let origin = CGPoint(x: 1900, y: 100)
        let frame = FloatingPlacement.restored(origin: origin, size: size, screens: [main, side])
        #expect(frame.origin == origin)
    }

    /// Its screen was unplugged: back to the default rather than lost off-screen.
    @Test func fallsBackWhenItsScreenIsGone() {
        let frame = FloatingPlacement.restored(origin: CGPoint(x: 1900, y: 100), size: size, screens: [main])
        #expect(frame == FloatingPlacement.defaultFrame(size: size, screens: [main]))
        #expect(FloatingPlacement.restored(origin: nil, size: size, screens: [main]) == frame)
    }

    @Test func shrinkingKeepsTheDockedCorner() {
        let dockedTopRight = FloatingPlacement.defaultFrame(size: size, screens: [main])
        let small = FloatingPlacement.resized(dockedTopRight, to: CGSize(width: 100, height: 100), screens: [main])
        #expect(small.maxX == dockedTopRight.maxX)
        #expect(small.maxY == dockedTopRight.maxY)

        let bottomLeft = CGRect(x: margin, y: margin, width: 300, height: 120)
        let grown = FloatingPlacement.resized(
            FloatingPlacement.resized(bottomLeft, to: CGSize(width: 100, height: 100), screens: [main]),
            to: size, screens: [main])
        #expect(grown == bottomLeft)
    }

    @Test func noScreensLeavesTheFrameAlone() {
        let frame = CGRect(x: 5, y: 5, width: 300, height: 120)
        #expect(FloatingPlacement.settled(frame, screens: []) == frame)
    }
}
