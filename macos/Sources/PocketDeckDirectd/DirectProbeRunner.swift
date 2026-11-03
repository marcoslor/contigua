#if POCKETDECK_DIRECT
import Darwin
import Foundation
import PocketDeckDirectCore
import Security

/// §2.6's real checks. Every one is read-only and none calls the toolkit; the
/// decision itself is `DirectProbe`, which K2 tests without this file. `--probe`
/// is the reviewer's to run (design §7.4); tests never start this binary.
enum DirectProbeRunner {
    static func run(checkEntitlement: Bool = true) -> DirectProbeResult {
        var checks = DirectProbeChecks.allClear
        checks.sipEnabled = systemIntegrityProtectionEnabled()
        let bootArguments = bootArgumentTokens()
        checks.amfiRelaxed = bootArguments.contains("amfi_get_out_of_my_way=1")
        checks.allowlistDisabled = bootArguments.contains("wifiaware_allowlist=0")
        checks.nanPresent = if_nametoindex("nan0") != 0
        checks.wifip2pdReachable = serviceLoaded("com.apple.wifip2pd")
        // This process is the helper. The app owns the "cannot reach the
        // socket" and "refused this app" answers, because only it sees them.
        checks.helperReachable = true
        checks.peerCheckPassed = true
        checks.entitlementGranted = checkEntitlement ? carriesWiFiAwareEntitlement() : true
        return DirectProbe.evaluate(checks)
    }

    private static func systemIntegrityProtectionEnabled() -> Bool {
        // Fail closed: an answer we could not read is not proof that SIP is
        // off, and a wrong "ready" would make the provider fail later.
        guard let output = command("/usr/bin/csrutil", ["status"]) else { return true }
        return output.contains("System Integrity Protection status: enabled")
    }

    private static func bootArgumentTokens() -> Set<String> {
        guard let output = command("/usr/sbin/nvram", ["boot-args"]) else { return [] }
        return Set(output.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// The launchd job is the read-only stand-in for a Mach round trip, which
    /// only an entitled client can make (design §2.6).
    private static func serviceLoaded(_ name: String) -> Bool {
        guard let output = command("/bin/launchctl", ["print", "system/\(name)"]) else {
            return false
        }
        return output.contains("state =")
    }

    /// The helper's own signature, not the toolkit's answer: a process Apple
    /// killed for the entitlement never reaches this code, so the app's
    /// `directd_not_running` covers that case (§2.6).
    private static func carriesWiFiAwareEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.wifi-aware" as CFString, nil)
        return value != nil
    }

    private static func command(_ path: String, _ arguments: [String],
                                timeoutSeconds: Double = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
#endif
