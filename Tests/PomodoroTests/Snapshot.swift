import Foundation

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
}
