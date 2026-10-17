// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomodoroCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PomodoroCore", targets: ["PomodoroCore"]),
    ],
    targets: [
        .target(name: "PomodoroCore"),
        .testTarget(name: "PomodoroCoreTests", dependencies: ["PomodoroCore"]),
    ]
)
