import XCTest
@testable import Contigua

final class DebugControlTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-debug-control-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes NAME.cmd the way the e2e harness does (tmp file, then rename) and
    /// spins the main run loop until NAME.done appears.
    private func send(_ line: String, as name: String) throws -> String? {
        let tmp = directory.appendingPathComponent(name + ".tmp")
        try Data((line + "\n").utf8).write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: directory.appendingPathComponent(name + ".cmd"))
        let done = directory.appendingPathComponent(name + ".done")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? String(contentsOf: done, encoding: .utf8) { return text }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    func testCommandsRunInOrderAndAreAnswered() throws {
        var seen: [[String]] = []
        let control = DebugControl(directory: directory.path) { command, arguments in
            seen.append([command] + arguments)
            return command == "open" ? nil : "unknown command"
        }
        control.start()
        XCTAssertEqual(try send("open --open com.whatsapp --float-windows", as: "c1"), "ok\n")
        XCTAssertEqual(try send("bogus", as: "c2"), "unknown command\n")
        XCTAssertEqual(seen, [["open", "--open", "com.whatsapp", "--float-windows"], ["bogus"]])
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(left.contains { $0.hasSuffix(".cmd") }, "a command file is deleted once it ran")
    }

    func testEmptyCommandIsRefused() throws {
        let control = DebugControl(directory: directory.path) { _, _ in
            XCTFail("an empty command never reaches the handler")
            return nil
        }
        control.start()
        XCTAssertEqual(try send("  ", as: "c1"), "empty command\n")
    }
}
