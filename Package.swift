// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacIDM",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacIDM", targets: ["MacIDM"]),
        .executable(name: "MacIDMHost", targets: ["MacIDMHost"]),
        .library(name: "MacIDMCore", targets: ["MacIDMCore"]),
    ],
    targets: [
        // UI-independent download engine (testable on its own).
        .target(name: "MacIDMCore", path: "Sources/MacIDMCore"),
        .executableTarget(name: "MacIDM", dependencies: ["MacIDMCore"], path: "Sources/MacIDM"),
        // Native messaging host for the browser extension; bundled inside MacIDM.app.
        .executableTarget(name: "MacIDMHost", dependencies: ["MacIDMCore"], path: "Sources/MacIDMHost"),
        .testTarget(name: "MacIDMCoreTests", dependencies: ["MacIDMCore"], path: "Tests/MacIDMCoreTests"),
    ]
)
