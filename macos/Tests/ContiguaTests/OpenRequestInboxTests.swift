import XCTest
@testable import Contigua

final class OpenRequestInboxTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pd-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testInertWithoutBackgroundMode() {
        let options = LaunchOptions.parse(["Contigua", "--profile", "e2e", "--open-requests", folder.path])
        XCTAssertEqual(options.openRequests, folder.path)
        XCTAssertNil(OpenRequestInbox(options: options))
        XCTAssertNil(OpenRequestInbox(options: LaunchOptions.parse(["Contigua", "--profile", "e2e", "--background"])))
        XCTAssertNil(OpenRequestInbox(options: LaunchOptions.parse(["Contigua", "--background", "--open-requests", "rel"])))
    }

    func testTakesRequestsInOrderAndRemovesThem() throws {
        let options = LaunchOptions.parse(["Contigua", "--profile", "e2e", "--background", "--open-requests", folder.path])
        let inbox = try XCTUnwrap(OpenRequestInbox(options: options))
        try "/tmp/b.apk\n".write(to: folder.appendingPathComponent("2.path"), atomically: true, encoding: .utf8)
        try "/tmp/a.apk\nrelative\n".write(to: folder.appendingPathComponent("1.path"), atomically: true, encoding: .utf8)
        try "/tmp/ignored".write(to: folder.appendingPathComponent("3.tmp"), atomically: true, encoding: .utf8)
        XCTAssertEqual(inbox.take().map(\.path), ["/tmp/a.apk", "/tmp/b.apk"])
        XCTAssertEqual(inbox.take(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["3.tmp"])
    }
}
