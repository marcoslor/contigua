#if POCKETDECK_DIRECT
import Foundation
import XCTest
@testable import pocketdeck_directd

/// The real NAN adapter is never called under K2: there is no toolkit, no
/// entitlement and no radio here. What can be checked is that its pinned
/// names are still the proof's names, and that nothing in the suite loads it
/// (docs/design/direct-link.md §2.2).
final class ToolkitNanPortTests: XCTestCase {
    func testEveryPinnedSelectorIsStillInTheProofSource() throws {
        let source = try proofSource("sub.m")
        for selector in ToolkitNanPort.outgoingSelectors {
            XCTAssertTrue(source.contains(selector),
                          "\(selector) is no longer in the proof's source")
        }
        for prefix in ToolkitNanPort.callbackPrefixes {
            XCTAssertTrue(source.contains(prefix), "\(prefix) is no longer forwarded")
        }
        XCTAssertTrue(source.contains("WiFiAwareSubscribeConfiguration"))
        XCTAssertTrue(source.contains("WiFiAwareSubscriber"))
        XCTAssertTrue(source.contains("WiFiAwareDiscoveryResult"))
        XCTAssertTrue(source.contains("WiFiAwareDataSession"))
    }

    func testTheFrameworkAndTheRuntimeCallsAreTheProofs() throws {
        let source = try proofSource("proto.m")
        XCTAssertTrue(source.contains(ToolkitNanPort.frameworkPath))
        XCTAssertTrue(source.contains("objc_getProtocol"))
        XCTAssertTrue(source.contains("protocol_copyMethodDescriptionList"))
        XCTAssertTrue(source.contains("dlopen"))
    }

    func testTheProtocolLookupsAreWiFiAwareDelegateNames() {
        for name in ToolkitNanPort.protocolNames {
            XCTAssertTrue(name.hasPrefix("WiFiAware"), name)
            XCTAssertTrue(name.hasSuffix("Delegate"), name)
        }
        XCTAssertFalse(ToolkitNanPort.protocolNames.isEmpty)
    }

    func testNothingInTheSuiteLoadedTheToolkit() {
        XCTAssertFalse(ToolkitNanPort.loaded,
                       "a test must never dlopen the private toolkit")
        XCTAssertGreaterThan(ToolkitNanPort.outgoingSelectors.count, 0)
        XCTAssertFalse(ToolkitNanPort.loaded)
    }

    private func proofSource(_ name: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketDeckTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // the worktree
        let url = repo.appendingPathComponent("docs/research/wifi-aware-direct-link/probes")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
#endif
