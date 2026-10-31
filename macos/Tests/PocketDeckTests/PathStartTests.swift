// PATH-20 (docs/design/paths.md §9.1): every ready provider starts at once,
// exactly one plain hello is in flight, and the first welcome founds the
// session; every other finished attempt joins with that id.

import XCTest
@testable import PocketDeck

final class PathStartTests: XCTestCase {
    private func started(_ ids: [String]) -> PathStart {
        var start = PathStart()
        XCTAssertEqual(start.handle(.start(ids)), [])
        return start
    }

    func testTwoProvidersSendExactlyOnePlainHelloAndTheOtherJoins() {
        var start = started(["lan", "lan2"])
        XCTAssertEqual(start.handle(.ready("lan")), [.sendPlainHello("lan")])
        // The second attempt finished TLS while the hello is in flight: hold it.
        XCTAssertEqual(start.handle(.ready("lan2")), [])
        XCTAssertEqual(start.state, .hello(attempt: "lan"))
        XCTAssertEqual(start.held, ["lan2"])
        // The first welcome founds the session; the held attempt joins it.
        XCTAssertEqual(
            start.handle(.welcome(attempt: "lan", session: "s1")),
            [.sessionFounded("s1"), .sendJoin(["lan2"], session: "s1")],
        )
        XCTAssertEqual(start.state, .founded(session: "s1"))
    }

    func testThePlainHelloMovesToTheNextFinishedAttemptWhenTheFirstFails() {
        var start = started(["lan", "lan2"])
        XCTAssertEqual(start.handle(.ready("lan")), [.sendPlainHello("lan")])
        XCTAssertEqual(start.handle(.ready("lan2")), [])
        // The plain-hello attempt failed before welcome: the held one takes it.
        XCTAssertEqual(start.handle(.attemptFailed("lan")), [.sendPlainHello("lan2")])
        XCTAssertEqual(start.state, .hello(attempt: "lan2"))
    }

    func testThePlainHelloMovesToALaterArrivalWhenNothingIsHeldYet() {
        var start = started(["lan", "lan2"])
        XCTAssertEqual(start.handle(.ready("lan")), [.sendPlainHello("lan")])
        XCTAssertEqual(start.handle(.attemptFailed("lan")), [])
        XCTAssertEqual(start.state, .starting)
        // The other provider finishes later and sends the one plain hello.
        XCTAssertEqual(start.handle(.ready("lan2")), [.sendPlainHello("lan2")])
    }

    func testTheStartFailsOnlyWhenEveryProviderFailed() {
        var start = started(["lan", "lan2"])
        XCTAssertEqual(start.handle(.ready("lan")), [.sendPlainHello("lan")])
        XCTAssertEqual(start.handle(.attemptFailed("lan")), [])
        // lan2 is still dialing: not a failure yet.
        XCTAssertEqual(start.state, .starting)
        XCTAssertEqual(start.handle(.attemptFailed("lan2")), [.fail])
        XCTAssertEqual(start.state, .failed)
    }

    func testADirectOnlyStartFoundsTheSessionLikeAnyOther() {
        var start = started(["direct"])
        XCTAssertEqual(start.handle(.ready("direct")), [.sendPlainHello("direct")])
        XCTAssertEqual(
            start.handle(.welcome(attempt: "direct", session: "s2")),
            [.sessionFounded("s2")],
        )
        XCTAssertEqual(start.state, .founded(session: "s2"))
    }

    func testAWelcomeFromAnAttemptThatDoesNotHoldTheHelloIsIgnored() {
        var start = started(["lan", "lan2"])
        _ = start.handle(.ready("lan"))
        _ = start.handle(.ready("lan2"))
        XCTAssertEqual(start.handle(.welcome(attempt: "lan2", session: "s3")), [])
        XCTAssertEqual(start.state, .hello(attempt: "lan"))
    }

    func testAFailedAttemptNeverSendsAPlainHello() {
        var start = started(["lan", "lan2"])
        XCTAssertEqual(start.handle(.attemptFailed("lan")), [])
        XCTAssertEqual(start.handle(.ready("lan2")), [.sendPlainHello("lan2")])
        XCTAssertEqual(start.held, [])
    }
}
