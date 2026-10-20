// The force click's decision (docs/design/livetext.md "Force click").

import AppKit
import XCTest
@testable import PocketDeck

final class ForceClickTests: XCTestCase {
    func testASubjectInTheModeCopies() {
        XCTAssertEqual(ForceClick.action(active: true, subjectAtPoint: true), .copy)
    }

    func testTextOrEmptyAreaKeepsTheSystemsLookUp() {
        XCTAssertEqual(ForceClick.action(active: true, subjectAtPoint: false), .system)
    }

    func testOutsideTheModeNothingIsAnalysedOrCopied() {
        XCTAssertEqual(ForceClick.action(active: false, subjectAtPoint: true), .system)
        XCTAssertEqual(ForceClick.action(active: false, subjectAtPoint: false), .system)
    }

    func testTheDebugGrammarCarriesTheForceClick() throws {
        let actions = try LiveTextDebugScript.parse("forceclick 0.5 0.25\n")
        XCTAssertEqual(actions, [.forceClick(x: 0.5, y: 0.25)])
        XCTAssertThrowsError(try LiveTextDebugScript.parse("forceclick 1.5 0.5"))
        XCTAssertThrowsError(try LiveTextDebugScript.parse("forceclick 0.5"))
    }
}
