import AppKit
import XCTest
@testable import PocketDeck

final class DebugInputTests: XCTestCase {

    func testParsesEveryVerb() throws {
        let actions = try DebugInputScript.parse("""
        click 0.25 0.75
        rightclick 0.5 0.5
        drag 0.1 0.2 0.8 0.9
        scroll 3 0.4 0.6
        pinch 0.5 0.5 1.5
        rotate 0.4 0.6 -90
        trackscroll 240 0.4 0.6
        fingerscroll -120
        fingerpinch 0.5 0.5 1.8
        fingerpinch 0.5 0.5 0.5 3
        fingerrotate 0.5 0.5 45
        showtouches on
        strip off
        strip on
        hover 0.5 0
        wait 2.5
        type hi
        key esc
        """)
        XCTAssertEqual(actions, [
            .click(NormalizedPoint(nx: 0.25, ny: 0.75)),
            .rightClick(NormalizedPoint(nx: 0.5, ny: 0.5)),
            .drag(from: NormalizedPoint(nx: 0.1, ny: 0.2), to: NormalizedPoint(nx: 0.8, ny: 0.9)),
            .scroll(dy: 3, at: NormalizedPoint(nx: 0.4, ny: 0.6)),
            .pinch(at: NormalizedPoint(nx: 0.5, ny: 0.5), scale: 1.5),
            .rotate(at: NormalizedPoint(nx: 0.4, ny: 0.6), degrees: -90),
            .trackScroll(dy: 240, at: NormalizedPoint(nx: 0.4, ny: 0.6)),
            .fingerScroll(dy: -120, at: .center),
            .fingerPinch(at: .center, scale: 1.8, hold: 0),
            .fingerPinch(at: .center, scale: 0.5, hold: 3),
            .fingerRotate(at: .center, degrees: 45, hold: 0),
            .showTouches(true),
            .strip(false),
            .strip(true),
            .hover(NormalizedPoint(nx: 0.5, ny: 0)),
            .wait(2.5),
            .type("hi"),
            .key(KeyStroke(keyCode: 53, characters: "\u{1b}")),
        ])
    }

    func testBlankLinesAndCommentsAreSkipped() throws {
        let actions = try DebugInputScript.parse("\n  # set up\n\nclick 0.5 0.5\n   \n")
        XCTAssertEqual(actions, [.click(.center)])
    }

    func testEmptyScriptIsValid() throws {
        XCTAssertEqual(try DebugInputScript.parse(""), [])
    }

    func testScrollDefaultsToTheCentre() throws {
        XCTAssertEqual(try DebugInputScript.parse("scroll -2"), [.scroll(dy: -2, at: .center)])
    }

    func testTypeKeepsTheRestOfTheLine() throws {
        XCTAssertEqual(try DebugInputScript.parse("type two words"), [.type("two words")])
    }

    func testKeyModifiersAndNames() throws {
        let actions = try DebugInputScript.parse("""
        key cmd+[
        key cmd+shift+h
        key cmd+up
        key ctrl+opt+x
        """)
        XCTAssertEqual(actions, [
            .key(KeyStroke(keyCode: 33, characters: "[", command: true)),
            .key(KeyStroke(keyCode: 4, characters: "H", command: true, shift: true)),
            .key(KeyStroke(keyCode: 126, characters: "\u{F700}", command: true)),
            .key(KeyStroke(keyCode: 7, characters: "x", control: true, option: true)),
        ])
    }

    func testRejectsUnknownActionWithItsLine() {
        XCTAssertThrowsError(try DebugInputScript.parse("click 0.5 0.5\nwiggle 1 2")) { error in
            XCTAssertEqual(error as? DebugInputParseError,
                           DebugInputParseError(line: 2, message: "unknown action 'wiggle'"))
        }
    }

    func testRejectsCoordinatesOutsideTheVideo() {
        XCTAssertThrowsError(try DebugInputScript.parse("click 1.5 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("drag 0 0 0 -0.1"))
        XCTAssertThrowsError(try DebugInputScript.parse("click abc 0.5"))
    }

    func testRejectsMissingArguments() {
        XCTAssertThrowsError(try DebugInputScript.parse("click 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("drag 0.1 0.2 0.3"))
        XCTAssertThrowsError(try DebugInputScript.parse("scroll"))
        XCTAssertThrowsError(try DebugInputScript.parse("scroll 3 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("pinch 0.5 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("rotate 0.5 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("type"))
        XCTAssertThrowsError(try DebugInputScript.parse("key"))
        XCTAssertThrowsError(try DebugInputScript.parse("trackscroll"))
        XCTAssertThrowsError(try DebugInputScript.parse("fingerpinch 0.5 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("strip")) { error in
            XCTAssertEqual((error as? DebugInputParseError)?.message, "strip needs on or off")
        }
        XCTAssertThrowsError(try DebugInputScript.parse("strip maybe"))
        XCTAssertThrowsError(try DebugInputScript.parse("showtouches"))
        XCTAssertThrowsError(try DebugInputScript.parse("fingerpinch 0.5 0.5 2 -1"))
        XCTAssertThrowsError(try DebugInputScript.parse("pinch 0.5 0.5 2 3"))
        XCTAssertThrowsError(try DebugInputScript.parse("hover 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("wait"))
        XCTAssertThrowsError(try DebugInputScript.parse("wait 600"))
    }

    func testRejectsANonPositivePinchScale() {
        XCTAssertThrowsError(try DebugInputScript.parse("pinch 0.5 0.5 0")) { error in
            XCTAssertEqual((error as? DebugInputParseError)?.message, "pinch needs NX NY SCALE (SCALE > 0)")
        }
        XCTAssertThrowsError(try DebugInputScript.parse("pinch 0.5 0.5 -2"))
        XCTAssertThrowsError(try DebugInputScript.parse("pinch 0.5 0.5 big"))
    }

    func testRejectsUnknownKeysAndModifiers() {
        XCTAssertThrowsError(try DebugInputScript.parse("key f13")) { error in
            XCTAssertEqual((error as? DebugInputParseError)?.message, "unknown key 'f13'")
        }
        XCTAssertThrowsError(try DebugInputScript.parse("key hyper+a")) { error in
            XCTAssertEqual((error as? DebugInputParseError)?.message, "unknown modifier 'hyper'")
        }
        XCTAssertThrowsError(try DebugInputScript.parse("key +"))
    }

    func testViewPointInvertsLetterboxNormalization() {
        let videoRect = CGRect(x: 40, y: 10, width: 300, height: 500)
        for flipped in [false, true] {
            for point in [NormalizedPoint.center, NormalizedPoint(nx: 0, ny: 0), NormalizedPoint(nx: 1, ny: 0.2)] {
                let view = DebugInputDriver.viewPoint(point, videoRect: videoRect, flipped: flipped)
                let back = Letterbox.normalized(point: view, videoRect: videoRect, flipped: flipped)
                XCTAssertEqual(Double(back.nx), point.nx, accuracy: 1e-5)
                XCTAssertEqual(Double(back.ny), point.ny, accuracy: 1e-5)
            }
        }
    }
}
