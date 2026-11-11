// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Contigua",
    platforms: [.macOS("26.0")],
    dependencies: [
        // v2 TLS transport (docs/design/e2ee.md §1): SwiftNIO-SSL vendoring
        // BoringSSL in-memory, same major line the spikes proved.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        // Pinned to the collection line the spikes run against: newer majors
        // need newer compiler features than tools-version 5.10 allows.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
    ],
    targets: [
        // The app is a single executable target so its wiring (AppKit views,
        // windows, session) can be exercised directly by the test target.
        .executableTarget(
            name: "Contigua",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Sources/Contigua",
            // Debug builds keep the e2e launch hooks (tests and local runs);
            // release builds only get them when bundle.sh passes the same
            // define for an e2e bundle (sec L-6).
            swiftSettings: [.define("PD_TEST_HOOKS", .when(configuration: .debug))]
        ),
        .testTarget(name: "ContiguaTests", dependencies: ["Contigua"], path: "Tests/ContiguaTests"),
    ]
)
