// PATH-2: there is no reduced transport. A protocol-4 session always has the
// path layer, and a refused version is never retried as a single connection.

import XCTest
@testable import Contigua

final class NoFallbackTests: XCTestCase {
    func testTheSessionLayerIsAlwaysOn() {
        XCTAssertTrue(NoFallback.sessionLayerAlwaysOn)
    }

    func testAVersionMismatchIsARefusalNotASingleConnectionRetry() {
        XCTAssertTrue(NoFallback.isRefusedAsAVersionMismatch(code: "version"))
        XCTAssertFalse(NoFallback.isRefusedAsAVersionMismatch(code: "busy"))
        // The owner's retry rule agrees: "version" is terminal.
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("version"))
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("not_paired"))
        XCTAssertTrue(ConnectionFailure.retriesAutomatically("tls"))
    }
}
