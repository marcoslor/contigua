// PATH-53 (#190, #159): a session's event-loop group outlives every dial that
// was started on it. A close while a dial is still running must not shut the
// group down under that dial: NIO then drops the dial's work and prints
// "Cannot schedule tasks on an EventLoop that has already shut down".

import Darwin
import XCTest
@testable import Contigua

final class SessionDialGroupTests: XCTestCase {
    private var server: FakeServer!

    override func tearDown() {
        server?.stop()
    }

    /// Everything written to fd 2 while `body` runs (NIO's printError goes there).
    private func capturingStandardError(_ body: () -> Void) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stderr-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        dup2(handle.fileDescriptor, STDERR_FILENO)
        body()
        fflush(stderr)
        dup2(saved, STDERR_FILENO)
        close(saved)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testPATH53_ADialStillRunningWhenTheSessionClosesNeverMeetsAShutDownLoop() throws {
        let mac = IdentityGeneratorV2.make(deviceId: "mac-\(UUID().uuidString.prefix(8))")
        let phone = IdentityGeneratorV2.make(deviceId: "phone-\(UUID().uuidString.prefix(8))",
                                             cn: "Contigua Phone").identity
        server = try FakeServer(phoneIdentity: phone, trustingClientPem: mac.identity.certPem)
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: server.port),
                              knownDeviceId: nil, clientId: "test-client",
                              identity: mac.identity, connectTimeout: 4, pairingTimeout: 20)
        session.pairingPolicy = .allowed

        // The dial is held at its start until the session has fully closed.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let dialDone = DispatchSemaphore(value: 0)
        session.dialGateForTests = {
            entered.signal()
            release.wait()
        }
        session.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the dial never started")

        session.closeAndWait(timeout: 3)

        let output = try capturingStandardError {
            release.signal()
            // The dial reaches the phone's TLS server (or fails) and its
            // result comes back to the session queue; give it the handshake's
            // own bound and then some.
            DispatchQueue.global().async {
                // A dial on a live loop ends well inside 3 s against the fake.
                Thread.sleep(forTimeInterval: 3)
                dialDone.signal()
            }
            _ = dialDone.wait(timeout: .now() + 5)
        }
        XCTAssertFalse(output.contains("already shut down"),
                       "a dial ran on the session's group after close shut it down")
        withExtendedLifetime(session) {}
    }
}
