#if POCKETDECK_DIRECT
import Foundation
import XCTest
@testable import PocketDeckDirectCore

/// The socket API's NAN additions (docs/design/direct-link.md §2.5, transport
/// DIRECT-4): the key and the service on a `dial`, `discover`, `stop`, and the
/// toolkit's truthful `hello`.
final class DirectNanAPITests: XCTestCase {
    private let key = String(repeating: "00", count: 32)
    private let peer = String(repeating: "ab", count: 16)
    private let service = "_pocketdeck-nan._tcp"

    private func parse(_ json: String) throws -> DirectRequest {
        try DirectRequestParser.parse(Data(json.utf8))
    }

    func testDialCarriesTheKeyTheServiceAndThePeer() throws {
        let json = #"{"op":"dial","peer":"\#(peer)","svc":"\#(service)","psk":"\#(key)","port":47990}"#
        XCTAssertEqual(try parse(json),
                       .dial(DirectDial(peer: peer, service: service, psk: key,
                                        port: 47990)))
    }

    func testDialWithoutTheNanFieldsIsStillTheTestPeersDial() throws {
        XCTAssertEqual(try parse(#"{"op":"dial","port":47990}"#),
                       .dial(DirectDial(peer: nil, service: nil, psk: nil,
                                        port: 47990)))
    }

    func testDialRefusesAPartialNanRequest() {
        let cases = [
            #"{"op":"dial","peer":"\#(peer)","port":1}"#,
            #"{"op":"dial","svc":"\#(service)","port":1}"#,
            #"{"op":"dial","psk":"\#(key)","port":1}"#,
            #"{"op":"dial","peer":"\#(peer)","svc":"\#(service)","port":1}"#,
            #"{"op":"dial","peer":"\#(peer)","psk":"\#(key)","port":1}"#,
            #"{"op":"dial","svc":"\#(service)","psk":"\#(key)","port":1}"#,
            #"{"op":"dial","peer":"\#(peer)","svc":"\#(service)","psk":"\#(String(repeating: "ab", count: 32).uppercased())","port":1}"#
        ]
        for json in cases {
            XCTAssertThrowsError(try parse(json), json)
        }
    }

    func testDiscoverNeedsTheServiceAndTheKey() throws {
        XCTAssertEqual(try parse(#"{"op":"discover","svc":"\#(service)","psk":"\#(key)"}"#),
                       .discover(service: service, psk: key))
        for json in [
            #"{"op":"discover"}"#,
            #"{"op":"discover","svc":"\#(service)"}"#,
            #"{"op":"discover","psk":"\#(key)"}"#,
            #"{"op":"discover","svc":"","psk":"\#(key)"}"#,
            #"{"op":"discover","svc":"\#(service)","psk":"abc"}"#,
            #"{"op":"discover","svc":"\#(service)","psk":"\#(String(repeating: "zz", count: 32))"}"#,
            #"{"op":"discover","svc":"\#(String(repeating: "s", count: 65))","psk":"\#(key)"}"#
        ] {
            XCTAssertThrowsError(try parse(json), json)
        }
    }

    func testStopIsEmpty() throws {
        XCTAssertEqual(try parse(#"{"op":"stop"}"#), .stop)
        XCTAssertEqual(try parse(#"{"op":"stop","link":"x"}"#), .stop)
    }

    func testHelloTellsTheTruthAboutTheToolkit() throws {
        let reply = DirectReply.hello(version: 1,
                                      toolkit: DirectToolkitReport(publish: false,
                                                                   subscribe: true,
                                                                   dataLinks: 8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply.encoded()) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["v"] as? Int, 1)
        let toolkit = try XCTUnwrap(object["toolkit"] as? [String: Any])
        XCTAssertEqual(toolkit["publish"] as? Bool, false)
        XCTAssertEqual(toolkit["subscribe"] as? Bool, true)
        XCTAssertEqual(toolkit["dataLinks"] as? Int, 8)
    }

    func testTheErrorCodesAreTheClosedList() {
        let codes = DirectWireCode.allCases
        XCTAssertEqual(Set(codes.map(\.rawValue)).count, codes.count)
        for code in [DirectWireCode.noKey, .ndpTimeout, .ndpRefused, .notReady, .busy] {
            XCTAssertTrue(codes.contains(code), code.rawValue)
        }
        XCTAssertEqual(DirectWireCode.noKey.rawValue, "no_key")
        XCTAssertEqual(DirectWireCode.ndpTimeout.rawValue, "ndp_timeout")
        XCTAssertEqual(DirectWireCode.ndpRefused.rawValue, "ndp_refused")
    }

    /// DIRECT-15: the one line that names the key carries its fingerprint and
    /// length, never the key or the passphrase.
    func testTheHelperLogsTheKeyOnlyByItsFingerprint() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repo.appendingPathComponent(
            "macos/Sources/PocketDeckDirectd/Directd.swift"), encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)
            .filter { $0.contains("nan key=") }
        XCTAssertEqual(lines.count, 1, "the key has exactly one log line")
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.contains("DirectKey.fingerprint(key)"), line)
        XCTAssertTrue(line.contains("len="), line)
        XCTAssertFalse(line.contains("passphrase"), line)
        XCTAssertFalse(line.contains("psk"), line)
    }

    func testANanFailureIsOneHonestReply() throws {
        let reply = DirectReply.error(.ndpTimeout, message: "the NDP did not come up")
        let data = reply.encoded()
        XCTAssertLessThanOrEqual(data.count, DirectLimits.replyBytes)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["code"] as? String, "ndp_timeout")
    }
}
#endif
