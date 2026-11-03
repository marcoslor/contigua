// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PocketDeck",
    platforms: [.macOS("26.0")],
    products: [
        // The direct-link helper (docs/design/direct-link.md §1.1). A plain
        // build compiles a stub; only macos/scripts/direct/build.sh passes
        // POCKETDECK_DIRECT, so the public app never links this.
        .executable(name: "pocketdeck-directd", targets: ["pocketdeck-directd"]),
    ],
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
            name: "PocketDeck",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Sources/PocketDeck",
            // Debug builds keep the e2e launch hooks (tests and local runs);
            // release builds only get them when bundle.sh passes the same
            // define for an e2e bundle (sec L-6).
            swiftSettings: [.define("PD_TEST_HOOKS", .when(configuration: .debug))]
        ),
        // The helper's pure parts: line framing, request parsing, the reply
        // shapes and the link machine. Everything is inside #if
        // POCKETDECK_DIRECT, so a public build compiles an empty module and
        // only the direct test run sees it (docs/design/direct-link.md §2.5).
        .target(name: "PocketDeckDirectCore", path: "Sources/PocketDeckDirectCore"),
        // lwIP 2.2.1 from upstream (macos/vendor/lwip/VENDORED.md), with the
        // netif/BPF glue §2.4 asks for. Linked only into the helper; a plain
        // build still type-checks it.
        .target(
            name: "PDLWIP",
            path: "vendor/lwip",
            sources: [
                "port/pdlbpf.c",
                "port/pdlwip.c",
                "src/core/def.c",
                "src/core/inet_chksum.c",
                "src/core/init.c",
                "src/core/ip.c",
                "src/core/mem.c",
                "src/core/memp.c",
                "src/core/netif.c",
                "src/core/pbuf.c",
                "src/core/sys.c",
                "src/core/tcp.c",
                "src/core/tcp_in.c",
                "src/core/tcp_out.c",
                "src/core/timeouts.c",
                "src/core/ipv6/ethip6.c",
                "src/core/ipv6/icmp6.c",
                "src/core/ipv6/inet6.c",
                "src/core/ipv6/ip6.c",
                "src/core/ipv6/ip6_addr.c",
                "src/core/ipv6/ip6_frag.c",
                "src/core/ipv6/nd6.c",
                "src/netif/ethernet.c",
            ],
            cSettings: [
                .headerSearchPath("port"),
                .headerSearchPath("src/include"),
            ]
        ),
        .executableTarget(
            name: "pocketdeck-directd",
            dependencies: ["PocketDeckDirectCore", "PDLWIP"],
            path: "Sources/PocketDeckDirectd"
        ),
        .testTarget(name: "PocketDeckTests",
                    dependencies: ["PocketDeck", "PocketDeckDirectCore", "PDLWIP"],
                    path: "Tests/PocketDeckTests"),
    ]
)
