import Testing
@testable import PomodoroCore

struct VersionTests {
    @Test func currentVersionFormatsAsSemver() {
        #expect(Version.current.description == "0.1.0")
    }
}
