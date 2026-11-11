import XCTest
@testable import Contigua

final class LiveTextModeTests: XCTestCase {

    private let reasons: [LiveTextExitReason] = [
        .escape, .toggle, .menu, .barButton, .resize, .close, .disconnect, .streamConfig,
        .captureFailed,
    ]

    func testStartsIdle() {
        let mode = LiveTextMode()
        XCTAssertEqual(mode.state, .idle)
        XCTAssertFalse(mode.isActive)
        XCTAssertNil(mode.lastExitReason)
    }

    func testEnterGoesToCapturing() {
        var mode = LiveTextMode()
        XCTAssertTrue(mode.handle(.enter))
        XCTAssertEqual(mode.state, .capturing)
        XCTAssertTrue(mode.isActive)
    }

    func testASecondEnterIsIgnoredInEveryOtherState() {
        for state in [LiveTextState.capturing, .analyzing, .shown] {
            var mode = modeIn(state)
            XCTAssertFalse(mode.handle(.enter), "enter while \(state)")
            XCTAssertEqual(mode.state, state, "enter while \(state)")
        }
    }

    func testFrameCapturedOnlyMovesCapturingToAnalyzing() {
        var mode = LiveTextMode()
        XCTAssertFalse(mode.handle(.frameCaptured), "a frame with no mode")
        XCTAssertEqual(mode.state, .idle)

        mode = modeIn(.capturing)
        XCTAssertTrue(mode.handle(.frameCaptured))
        XCTAssertEqual(mode.state, .analyzing)

        for state in [LiveTextState.analyzing, .shown] {
            var other = modeIn(state)
            XCTAssertFalse(other.handle(.frameCaptured), "frame while \(state)")
            XCTAssertEqual(other.state, state)
        }
    }

    func testAnalysisEndsInShown() {
        for event in [LiveTextEvent.analysisFinished, .analysisFailed] {
            var mode = modeIn(.analyzing)
            XCTAssertTrue(mode.handle(event), "\(event)")
            XCTAssertEqual(mode.state, .shown, "\(event)")
        }
    }

    func testAnalysisWithoutAnalyzingIsIgnored() {
        for state in [LiveTextState.idle, .capturing, .shown] {
            for event in [LiveTextEvent.analysisFinished, .analysisFailed] {
                var mode = modeIn(state)
                XCTAssertFalse(mode.handle(event), "\(event) while \(state)")
                XCTAssertEqual(mode.state, state)
            }
        }
    }

    func testEveryExitReasonLeavesEveryActiveState() {
        for state in [LiveTextState.capturing, .analyzing, .shown] {
            for reason in reasons {
                var mode = modeIn(state)
                XCTAssertTrue(mode.exit(reason), "\(reason) while \(state)")
                XCTAssertEqual(mode.state, .idle, "\(reason) while \(state)")
                XCTAssertEqual(mode.lastExitReason, reason)
            }
        }
    }

    func testExitWhileIdleDoesNothing() {
        var mode = LiveTextMode()
        XCTAssertFalse(mode.exit(.resize))
        XCTAssertEqual(mode.state, .idle)
        XCTAssertNil(mode.lastExitReason)
    }

    func testTheHappyPath() {
        var mode = LiveTextMode()
        XCTAssertEqual(mode.state, .idle)
        XCTAssertTrue(mode.handle(.enter))
        XCTAssertEqual(mode.state, .capturing)
        XCTAssertTrue(mode.handle(.frameCaptured))
        XCTAssertEqual(mode.state, .analyzing)
        XCTAssertTrue(mode.handle(.analysisFinished))
        XCTAssertEqual(mode.state, .shown)
        XCTAssertTrue(mode.exit(.escape))
        XCTAssertEqual(mode.state, .idle)
        XCTAssertEqual(mode.lastExitReason, .escape)
    }

    /// A mode sitting in `state`, reached through the real transitions.
    private func modeIn(_ state: LiveTextState) -> LiveTextMode {
        var mode = LiveTextMode()
        switch state {
        case .idle: break
        case .capturing: mode.handle(.enter)
        case .analyzing:
            mode.handle(.enter)
            mode.handle(.frameCaptured)
        case .shown:
            mode.handle(.enter)
            mode.handle(.frameCaptured)
            mode.handle(.analysisFinished)
        }
        XCTAssertEqual(mode.state, state)
        return mode
    }
}
