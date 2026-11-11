import XCTest
@testable import Contigua

final class LiveTextDebugScriptTests: XCTestCase {

    func testParsesTheE2EScript() throws {
        let text = """
        # the livetext check

        enter 1
        wait-analysis CONTIGUA
        waitfile /tmp/contigua-e2e-47954/lt-copy-go
        copy-image /tmp/contigua-e2e-47954/livetext.png
        exit
        wait-idle
        enter 2
        wait-analysis
        resize 2 1200 800
        wait-idle 15
        """
        let actions = try LiveTextDebugScript.parse(text)
        XCTAssertEqual(actions, [
            .enter(1),
            .waitAnalysis(token: "CONTIGUA"),
            .waitFile(path: "/tmp/contigua-e2e-47954/lt-copy-go", timeout: 30),
            .copyImage("/tmp/contigua-e2e-47954/livetext.png"),
            .exit,
            .waitIdle(timeout: 10),
            .enter(2),
            .waitAnalysis(token: nil),
            .resize(stream: 2, width: 1200, height: 800),
            .waitIdle(timeout: 15),
        ])
    }

    func testWaitWarmTakesAnOptionalTimeout() throws {
        XCTAssertEqual(try LiveTextDebugScript.parse("wait-warm"), [.waitWarm(timeout: 60)])
        XCTAssertEqual(try LiveTextDebugScript.parse("wait-warm 5.5"), [.waitWarm(timeout: 5.5)])
    }

    func testUnknownActionFailsWithItsLine() {
        XCTAssertThrowsError(try LiveTextDebugScript.parse("enter 1\nbogus")) { error in
            XCTAssertEqual("\(error)", "line 2: unknown action 'bogus'")
        }
    }

    func testCopyImageNeedsAnAbsolutePath() {
        XCTAssertThrowsError(try LiveTextDebugScript.parse("copy-image relative.png")) { error in
            XCTAssertEqual("\(error)", "line 1: copy-image needs an absolute OUT path")
        }
    }

    func testEnterNeedsAStream() {
        XCTAssertThrowsError(try LiveTextDebugScript.parse("enter")) { error in
            XCTAssertEqual("\(error)", "line 1: enter needs STREAM")
        }
    }

    func testResizeNeedsThreeNumbers() {
        XCTAssertThrowsError(try LiveTextDebugScript.parse("resize 1 900")) { error in
            XCTAssertEqual("\(error)", "line 1: resize needs STREAM W H")
        }
    }

    func testEmptyScriptIsNoActions() throws {
        XCTAssertEqual(try LiveTextDebugScript.parse("\n\n# nothing\n"), [])
    }
}
