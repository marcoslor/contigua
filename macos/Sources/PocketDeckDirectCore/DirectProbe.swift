#if POCKETDECK_DIRECT
import Foundation

/// A probe answer (docs/design/direct-link.md §2.6, transport DIRECT-3). The
/// code is the first failing check; the sentence is the one the settings row
/// shows (CONV-PD-09).
public enum DirectProbeCode: String, Sendable, Equatable, CaseIterable {
    case ok
    case sipEnabled = "sip_enabled"
    case amfiEnabled = "amfi_enabled"
    case allowlistEnabled = "allowlist_enabled"
    case entitlementDenied = "entitlement_denied"
    case nan0Absent = "nan0_absent"
    case wifip2pdUnreachable = "wifip2pd_unreachable"
    case directdNotRunning = "directd_not_running"
    case socketPermissions = "socket_permissions"

    public var sentence: String {
        switch self {
        case .ok:
            return "Direct link is ready."
        case .sipEnabled:
            return "System Integrity Protection is on. The installer prints the Recovery step."
        case .amfiEnabled:
            return "Code-signing checks are on. The installer prints the boot argument "
                + "(amfi_get_out_of_my_way=1)."
        case .allowlistEnabled:
            return "The Wi-Fi Aware allowlist is on. The installer prints the boot argument "
                + "(wifiaware_allowlist=0)."
        case .entitlementDenied:
            return "macOS refused the Wi-Fi Aware entitlement. See the installer's last step."
        case .nan0Absent:
            return "This Mac has no Wi-Fi Aware interface."
        case .wifip2pdUnreachable:
            return "The Wi-Fi Aware service is not answering. Restart the Mac."
        case .directdNotRunning:
            return "The direct link helper is not running. Run the installer again."
        case .socketPermissions:
            return "The direct link helper refused this app. Run the installer again."
        }
    }
}

/// The eight checks, injectable so the decision is a K2 unit test and no test
/// ever reads SIP, nvram or an entitlement. `allClear` is a machine that can
/// run the provider.
public struct DirectProbeChecks: Sendable, Equatable {
    public var sipEnabled: Bool
    public var amfiRelaxed: Bool
    public var allowlistDisabled: Bool
    public var entitlementGranted: Bool
    public var nanPresent: Bool
    public var wifip2pdReachable: Bool
    public var helperReachable: Bool
    public var peerCheckPassed: Bool

    public init(sipEnabled: Bool, amfiRelaxed: Bool, allowlistDisabled: Bool,
                entitlementGranted: Bool, nanPresent: Bool,
                wifip2pdReachable: Bool, helperReachable: Bool,
                peerCheckPassed: Bool) {
        self.sipEnabled = sipEnabled
        self.amfiRelaxed = amfiRelaxed
        self.allowlistDisabled = allowlistDisabled
        self.entitlementGranted = entitlementGranted
        self.nanPresent = nanPresent
        self.wifip2pdReachable = wifip2pdReachable
        self.helperReachable = helperReachable
        self.peerCheckPassed = peerCheckPassed
    }

    public static let allClear = DirectProbeChecks(
        sipEnabled: false, amfiRelaxed: true, allowlistDisabled: true,
        entitlementGranted: true, nanPresent: true, wifip2pdReachable: true,
        helperReachable: true, peerCheckPassed: true)
}

public struct DirectProbeResult: Sendable, Equatable {
    public let code: DirectProbeCode
    public let ready: Bool

    public init(code: DirectProbeCode, ready: Bool) {
        self.code = code
        self.ready = ready
    }

    public var sentence: String { code.sentence }

    public var codes: [String] { ready ? [] : [code.rawValue] }

    /// §2.5's `probe` reply shape, one line: `ok` says the probe ran, not that
    /// the machine is ready.
    public func jsonLine() -> String {
        let object: [String: Any] = ["ok": true, "ready": ready,
                                     "codes": codes, "detail": sentence]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"codes":[],"detail":"","ok":true,"ready":false}"#
        }
        return text
    }
}

public enum DirectProbe {
    /// The installer's order (§2.6). The first failing check names the code;
    /// later failures wait for the earlier one to be fixed, because each is a
    /// prerequisite of the next.
    public static let order: [DirectProbeCode] = [
        .sipEnabled, .amfiEnabled, .allowlistEnabled, .entitlementDenied,
        .nan0Absent, .wifip2pdUnreachable, .directdNotRunning, .socketPermissions
    ]

    public static func evaluate(_ checks: DirectProbeChecks) -> DirectProbeResult {
        let failures: [(code: DirectProbeCode, failed: Bool)] = [
            (.sipEnabled, checks.sipEnabled),
            (.amfiEnabled, !checks.amfiRelaxed),
            (.allowlistEnabled, !checks.allowlistDisabled),
            (.entitlementDenied, !checks.entitlementGranted),
            (.nan0Absent, !checks.nanPresent),
            (.wifip2pdUnreachable, !checks.wifip2pdReachable),
            (.directdNotRunning, !checks.helperReachable),
            (.socketPermissions, !checks.peerCheckPassed)
        ]
        if let failure = failures.first(where: { $0.failed }) {
            return DirectProbeResult(code: failure.code, ready: false)
        }
        return DirectProbeResult(code: .ok, ready: true)
    }
}
#endif
