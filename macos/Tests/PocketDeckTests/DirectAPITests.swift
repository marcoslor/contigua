#if POCKETDECK_DIRECT
import Foundation
import XCTest
@testable import PocketDeckDirectCore

final class DirectAPITests: XCTestCase {
    private func parse(_ json: String) throws -> DirectRequest {
        try DirectRequestParser.parse(Data(json.utf8))
    }

    func testHelloAndProbe() throws {
        XCTAssertEqual(try parse(#"{"op":"hello","v":1}"#), .hello(version: 1))
        XCTAssertEqual(try parse(#"{"op":"probe"}"#), .probe)
        for bad in [#"{"op":"hello"}"#, #"{"op":"hello","v":0}"#, #"{"op":"hello","v":true}"#] {
            XCTAssertThrowsError(try parse(bad), bad)
        }
    }

    func testPeerRequest() throws {
        let request = try parse(#"{"op":"peer","if":"feth0","mac":"66:65:74:68:00:01","ll":"fe80::1%feth1"}"#)
        guard case .peer(let spec) = request else { return XCTFail("not a peer request") }
        XCTAssertEqual(spec.interface, "feth0")
        XCTAssertEqual(spec.mac, "66:65:74:68:00:01")
        XCTAssertNotNil(IPv6Address.parse(spec.linkLocal))

        XCTAssertThrowsError(try parse(#"{"op":"peer","if":"feth0","mac":"66:65:74:68:00","ll":"fe80::1"}"#))
        XCTAssertThrowsError(try parse(#"{"op":"peer","if":"feth0","mac":"66:65:74:68:00:01","ll":"1.2.3.4"}"#))
        XCTAssertThrowsError(try parse(#"{"op":"peer","if":"","mac":"66:65:74:68:00:01","ll":"fe80::1"}"#))
    }

    func testDialFields() throws {
        XCTAssertEqual(try parse(#"{"op":"dial","port":47990}"#), .dial(port: 47990))
        XCTAssertEqual(try parse(#"{"op":"dial","peer":"0123456789abcdef0123456789abcdef","svc":"_pocketdeck-nan._tcp","psk":"0000000000000000000000000000000000000000000000000000000000000000","port":1}"#),
                       .dial(port: 1))
        for bad in [#"{"op":"dial"}"#, #"{"op":"dial","port":0}"#, #"{"op":"dial","port":70000}"#,
                    #"{"op":"dial","port":1,"psk":"abc"}"#,
                    #"{"op":"dial","port":1,"peer":"xyz"}"#] {
            XCTAssertThrowsError(try parse(bad), bad)
        }
    }

    func testCloseAndLinks() throws {
        XCTAssertEqual(try parse(#"{"op":"close","link":"0123456789abcdef"}"#),
                       .close(link: "0123456789abcdef"))
        XCTAssertThrowsError(try parse(#"{"op":"close","link":"0123"}"#))
        XCTAssertEqual(try parse(#"{"op":"links"}"#), .links)
    }

    func testUnknownAndMalformed() {
        XCTAssertThrowsError(try parse(#"{"op":"bogus"}"#))
        XCTAssertThrowsError(try parse(#"{"v":1}"#))
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse("[]"))
    }

    func testLineFraming() throws {
        var framer = DirectLineFramer()
        XCTAssertEqual(try framer.append(Data("{\"op\":".utf8)), [])
        let lines = try framer.append(Data("1}\n{\"op\":\"links\"}\n".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) },
                       ["{\"op\":1}", "{\"op\":\"links\"}"])
        XCTAssertEqual(framer.pendingBytes, 0)
    }

    func testLineTooLong() {
        var framer = DirectLineFramer()
        let long = String(repeating: "a", count: DirectLimits.requestBytes + 1)
        XCTAssertThrowsError(try framer.append(Data(long.utf8)))
    }

    func testRepliesAreOneObjectUnderTheCap() throws {
        let cases: [DirectReply] = [
            .hello(version: 1, dataLinks: 8),
            .probe(ready: false, codes: ["probe_unimplemented"], detail: "x"),
            .dial(link: "0123456789abcdef", mtu: 1500),
            .ok,
            .links([DirectLinkReport(link: "0123456789abcdef", peer: "66:65", state: "up")]),
            .error(.notReady, message: "no peer"),
        ]
        for reply in cases {
            let data = reply.encoded()
            XCTAssertLessThanOrEqual(data.count, DirectLimits.replyBytes)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(object)
        }
        let error = try JSONSerialization.jsonObject(with: DirectReply.error(.busy, message: "m").encoded()) as? [String: Any]
        XCTAssertEqual(error?["ok"] as? Bool, false)
        XCTAssertEqual(error?["code"] as? String, "busy")
    }

    func testPeerCheckIsTheConsoleUserOnly() {
        XCTAssertTrue(directPeerAllowed(peerUID: 501, consoleUID: 501))
        XCTAssertFalse(directPeerAllowed(peerUID: 502, consoleUID: 501))
        XCTAssertFalse(directPeerAllowed(peerUID: 0, consoleUID: 501))
    }

    func testIPv6RoundTrip() throws {
        for text in ["fe80::1", "fe80::", "fd00::abcd:1", "fe80::6465:74ff:fe68:1"] {
            let bytes = try XCTUnwrap(IPv6Address.parse(text))
            XCTAssertEqual(bytes.count, 16)
            XCTAssertEqual(IPv6Address.parse(IPv6Address.format(bytes)), bytes, text)
        }
        XCTAssertNotNil(IPv6Address.parse("fe80::1%feth1"))
        XCTAssertNil(IPv6Address.parse("fe80::zzzz"))
        XCTAssertNil(IPv6Address.parse("1.2.3.4"))
        XCTAssertNil(IPv6Address.parse("fe80::1::2"))
    }

    func testLinkMachineTransitions() {
        XCTAssertEqual(DirectLinkMachine.step(.connecting, .connected).0, .up)
        XCTAssertEqual(DirectLinkMachine.step(.connecting, .connectFailed).0, .down)
        XCTAssertEqual(DirectLinkMachine.step(.up, .peerClosed).0, .down)
        XCTAssertEqual(DirectLinkMachine.step(.up, .appClosed).0, .down)
        XCTAssertEqual(DirectLinkMachine.step(.down, .connected).0, .down)
        XCTAssertEqual(DirectLinkMachine.step(.down, .peerClosed).0, .down)
        // The closing actions always close the app's socket, so the app never
        // waits on a link that ended.
        XCTAssertTrue(DirectLinkMachine.step(.up, .peerClosed).1.contains(.closeAppSocket))
        XCTAssertTrue(DirectLinkMachine.step(.connecting, .connectFailed).1.contains(.closeAppSocket))
        XCTAssertEqual(DirectLinkMachine.step(.up, .connected).1, [])
    }
}
#endif
