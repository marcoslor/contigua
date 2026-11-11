// N1's Mac side (ISS-40): the session's NWParameters carry the video service
// class only behind stream.net=video.

import Network
import XCTest
@testable import Contigua

final class SessionNetStrategyTests: XCTestCase {
    private let target = Session.Endpoint.hostPort(host: "127.0.0.1", port: 47000)

    func testTheDefaultSessionKeepsTheBestEffortClass() {
        let parameters = Session.tcpParameters(for: target, net: .default)
        XCTAssertEqual(parameters.serviceClass, .bestEffort)
        // The rest of the dial's settings are unchanged.
        XCTAssertTrue(parameters.defaultProtocolStack.transportProtocol is NWProtocolTCP.Options)
    }

    func testVideoMarksTheSessionInteractiveVideo() {
        let parameters = Session.tcpParameters(for: target, net: .video)
        XCTAssertEqual(parameters.serviceClass, .interactiveVideo)
    }
}
