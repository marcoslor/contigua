// Camera extension activation probe (spike, v0.2 #7).
//
// Submits an OSSystemExtensionRequest for the camera extension in the VM and
// prints every delegate callback verbatim, so the run records the exact result
// or error. Build with `swiftc activate.swift -o activate`, ad-hoc sign it, and
// run it in the guest's GUI session; it never runs on the host.
//
//   ./activate dev.pocketdeck.mac.camera-e2e            # activate
//   ./activate --deactivate dev.pocketdeck.mac.camera-e2e
//
// Exit code 0 when the system reports completed/after-reboot, 1 on failure,
// 2 on timeout.

import Foundation
import SystemExtensions

private func say(_ line: String) {
    print(line)
    fflush(stdout)
}

final class Delegate: NSObject, OSSystemExtensionRequestDelegate {
    private let finish: (Int32) -> Void

    init(finish: @escaping (Int32) -> Void) {
        self.finish = finish
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        say("delegate replace-existing: existing=\(existing.bundleIdentifier)@\(existing.bundleVersion) " +
            "new=\(ext.bundleIdentifier)@\(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        say("delegate needs-user-approval")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let name = result == .completed ? "completed" : "willCompleteAfterReboot"
        say("delegate finished: result=\(result.rawValue) (\(name))")
        finish(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let e = error as NSError
        say("delegate failed: domain=\(e.domain) code=\(e.code) " +
            "description=\(e.localizedDescription)")
        for (key, value) in e.userInfo.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            say("delegate failed userInfo: \(key)=\(value)")
        }
        finish(1)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let deactivate = args.first == "--deactivate"
let identifier = (deactivate ? args.dropFirst().first : args.first) ?? ""
guard !identifier.isEmpty else {
    say("usage: activate [--deactivate] <extension bundle identifier>")
    exit(2)
}

say("request: \(deactivate ? "deactivate" : "activate") \(identifier)")
var exited = false
let delegate = Delegate { code in
    exited = true
    // Give the run loop a turn so the line flushes before exit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(code) }
}
let request = deactivate
    ? OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main)
    : OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier, queue: .main)
request.delegate = delegate
OSSystemExtensionManager.shared.submitRequest(request)
say("submitted")

let deadline = Date().addingTimeInterval(90)
while !exited && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
}
if !exited {
    say("timeout: no delegate callback within 90 s")
    exit(2)
}
