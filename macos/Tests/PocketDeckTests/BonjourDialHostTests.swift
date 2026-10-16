// A Bonjour-resolved port comes back interface-scoped ("192.168.1.5%en0") and
// the NIO dial rejected it, so automatic discovery never connected to a real
// phone on the LAN. dialableHost is the pure conversion; NIO's parser is the
// oracle for what a dial actually accepts.

import NIOCore
import Network
import XCTest
@testable import PocketDeck

final class BonjourDialHostTests: XCTestCase {
    func testPlainIPv4KeepsItsAddress() {
        XCTAssertEqual(Session.dialableHost("192.168.1.5"), "192.168.1.5")
    }

    func testScopedIPv4DropsTheInterface() {
        XCTAssertEqual(Session.dialableHost("192.168.1.5%en0"), "192.168.1.5")
        XCTAssertEqual(Session.dialableHost("10.0.0.7%utun3"), "10.0.0.7")
    }

    func testGlobalIPv6DropsTheScope() {
        XCTAssertEqual(Session.dialableHost("2001:db8::1"), "2001:db8::1")
        XCTAssertEqual(Session.dialableHost("2001:db8::1%en0"), "2001:db8::1")
    }

    func testLinkLocalIPv6KeepsItsScope() {
        XCTAssertEqual(Session.dialableHost("fe80::c1:2%en0"), "fe80::c1:2%en0")
        XCTAssertEqual(Session.dialableHost("febf::1%en1"), "febf::1%en1")
        // Without a zone it stays a bare link-local address, not nil.
        XCTAssertEqual(Session.dialableHost("fe80::1"), "fe80::1")
    }

    func testEmptyOrJunkIsRejected() {
        XCTAssertNil(Session.dialableHost(""))
        XCTAssertNil(Session.dialableHost("   "))
        XCTAssertNil(Session.dialableHost("%en0"))
        XCTAssertNil(Session.dialableHost("192.168.1.5/24"))
    }

    /// NIO's own parser is what used to throw failedToParseIPString.
    func testNioAcceptsEveryConvertedForm() throws {
        for raw in ["192.168.1.5", "192.168.1.5%en0", "2001:db8::1", "2001:db8::1%en0",
                    "fe80::c1:2%en0", "fe80::1"] {
            let host = try XCTUnwrap(Session.dialableHost(raw), raw)
            XCTAssertNoThrow(try SocketAddress(ipAddress: host, port: 47810), raw)
        }
    }

    /// The endpoint hosts Network.framework hands the resolver, end to end.
    func testResolvedEndpointHostsAreDialable() throws {
        let scopedV4 = NWEndpoint.Host.ipv4(IPv4Address("192.168.1.5")!)
        XCTAssertEqual(Session.ipAddressString(scopedV4), "192.168.1.5")
        let linkLocal = NWEndpoint.Host.ipv6(IPv6Address("fe80::c1:2%en0")!)
        XCTAssertEqual(Session.ipAddressString(linkLocal), "fe80::c1:2%en0")
        let globalV6 = NWEndpoint.Host.ipv6(IPv6Address("2001:db8::1%en0")!)
        XCTAssertEqual(Session.ipAddressString(globalV6), "2001:db8::1")
    }
}
