// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClickShift",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClickShift", path: "Sources/ClickShift"),
        .testTarget(name: "ClickShiftTests", dependencies: ["ClickShift"], path: "Tests/ClickShiftTests"),
    ]
)
