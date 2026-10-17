// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomodoroCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PomodoroCore", targets: ["PomodoroCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "PomodoroCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "PomodoroCoreTests",
            dependencies: ["PomodoroCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
