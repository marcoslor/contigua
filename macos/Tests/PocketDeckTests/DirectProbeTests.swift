#if POCKETDECK_DIRECT
import Foundation
import XCTest
@testable import PocketDeckDirectCore

/// The probe at launch (docs/design/direct-link.md §2.6, transport DIRECT-3):
/// a pure decision over injectable checks, every code, the installer's order
/// and the one JSON line.
final class DirectProbeTests: XCTestCase {
    func testAllClearIsReady() {
        let result = DirectProbe.evaluate(.allClear)
        XCTAssertEqual(result.code, .ok)
        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.codes, [])
        XCTAssertEqual(result.jsonLine(),
                       #"{"codes":[],"detail":"Direct link is ready.","ok":true,"ready":true}"#)
    }

    func testEveryCodeInTheInstallersOrder() {
        let cases: [(DirectProbeCode, (inout DirectProbeChecks) -> Void)] = [
            (.sipEnabled, { $0.sipEnabled = true }),
            (.amfiEnabled, { $0.amfiRelaxed = false }),
            (.allowlistEnabled, { $0.allowlistDisabled = false }),
            (.entitlementDenied, { $0.entitlementGranted = false }),
            (.nan0Absent, { $0.nanPresent = false }),
            (.wifip2pdUnreachable, { $0.wifip2pdReachable = false }),
            (.directdNotRunning, { $0.helperReachable = false }),
            (.socketPermissions, { $0.peerCheckPassed = false })
        ]
        XCTAssertEqual(DirectProbe.order, cases.map(\.0),
                       "the table order is the installer's order")
        for (code, fail) in cases {
            var checks = DirectProbeChecks.allClear
            fail(&checks)
            let result = DirectProbe.evaluate(checks)
            XCTAssertEqual(result.code, code, "\(code.rawValue)")
            XCTAssertFalse(result.ready)
            XCTAssertEqual(result.codes, [code.rawValue])
            XCTAssertEqual(result.jsonLine().hasSuffix("\n"), false)
        }
    }

    func testTheFirstFailureWinsInOrder() {
        var checks = DirectProbeChecks.allClear
        checks.sipEnabled = true
        checks.amfiRelaxed = false
        checks.allowlistDisabled = false
        checks.entitlementGranted = false
        checks.nanPresent = false
        checks.wifip2pdReachable = false
        checks.helperReachable = false
        checks.peerCheckPassed = false
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .sipEnabled)

        checks.sipEnabled = false
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .amfiEnabled)
        checks.amfiRelaxed = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .allowlistEnabled)
        checks.allowlistDisabled = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .entitlementDenied)
        checks.entitlementGranted = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .nan0Absent)
        checks.nanPresent = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .wifip2pdUnreachable)
        checks.wifip2pdReachable = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .directdNotRunning)
        checks.helperReachable = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .socketPermissions)
        checks.peerCheckPassed = true
        XCTAssertEqual(DirectProbe.evaluate(checks).code, .ok)
    }

    func testTheFailureLineIsOneObjectUnderTheCap() throws {
        var checks = DirectProbeChecks.allClear
        checks.amfiRelaxed = false
        let data = Data(DirectProbe.evaluate(checks).jsonLine().utf8)
        XCTAssertLessThanOrEqual(data.count, DirectLimits.replyBytes)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true, "the probe itself ran")
        XCTAssertEqual(object["ready"] as? Bool, false)
        XCTAssertEqual(object["codes"] as? [String], ["amfi_enabled"])
        XCTAssertEqual(object["detail"] as? String,
                       DirectProbeCode.amfiEnabled.sentence)
    }

    func testEveryCodeIsTheClosedList() {
        XCTAssertEqual(DirectProbeCode.allCases.map(\.rawValue), [
            "ok", "sip_enabled", "amfi_enabled", "allowlist_enabled",
            "entitlement_denied", "nan0_absent", "wifip2pd_unreachable",
            "directd_not_running", "socket_permissions"
        ])
        for code in DirectProbeCode.allCases {
            XCTAssertFalse(code.sentence.isEmpty, code.rawValue)
            XCTAssertTrue(code.sentence.hasSuffix("."), code.rawValue)
            if code != .ok {
                XCTAssertTrue(code.sentence.contains("installer") ||
                              code.sentence.contains("Restart") ||
                              code.sentence.contains("Run the installer") ||
                              code.sentence.contains("no Wi-Fi Aware interface") ||
                              code.sentence.contains("refused this app"),
                              code.sentence)
            }
        }
        XCTAssertEqual(DirectProbeCode.ok.sentence, "Direct link is ready.")
    }
}
#endif
