// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PocketDeck",
    platforms: [.macOS("26.0")],
    targets: [
        // The app is a single executable target so its wiring (AppKit views,
        // windows, session) can be exercised directly by the test target.
        .executableTarget(name: "PocketDeck", path: "Sources/PocketDeck"),
        .testTarget(name: "PocketDeckTests", dependencies: ["PocketDeck"], path: "Tests/PocketDeckTests"),
    ]
)
