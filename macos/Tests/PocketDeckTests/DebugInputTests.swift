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
        dockapps off
        hover 0.5 0
        notifyclick pd-n1
        mediacmd play
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
            .dockApps(false),
            .hover(NormalizedPoint(nx: 0.5, ny: 0)),
            .notifyClick("pd-n1"),
            .mediaCommand("play"),
            .wait(2.5),
            .type("hi"),
            .key(KeyStroke(keyCode: 53, characters: "\u{1b}")),
        ])
    }

    func testParsesTheMediaPartTwoVerbs() throws {
        let actions = try DebugInputScript.parse("""
        mediacmd seek 45000
        mediacmd volume 9
        mediacmd choose s2
        """)
        XCTAssertEqual(actions, [
            .mediaSeek(45_000),
            .mediaVolume(9),
            .mediaChoose("s2"),
        ])
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd seek"))
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd seek -1"))
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd volume loud"))
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd choose"))
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd rewind"))
    }

    func testParsesNotifyPartTwoVerbs() throws {
        let actions = try DebugInputScript.parse("""
        notifyaction pd-a1 1 hello there
        notifyaction pd-a1 0
        notifydismiss pd-a2
        notifycopy pd-a4
        """)
        XCTAssertEqual(actions, [
            .notifyAction("pd-a1", 1, "hello there"),
            .notifyAction("pd-a1", 0, nil),
            .notifyDismiss("pd-a2"),
            .notifyCopy("pd-a4"),
        ])
        XCTAssertThrowsError(try DebugInputScript.parse("notifyaction pd-a1"))
        XCTAssertThrowsError(try DebugInputScript.parse("notifyaction pd-a1 -1"))
        XCTAssertThrowsError(try DebugInputScript.parse("notifydismiss"))
        XCTAssertThrowsError(try DebugInputScript.parse("notifycopy"))
    }

    func testParsesTheQuietRunVerbs() throws {
        let actions = try DebugInputScript.parse("""
        hoverat 0 200
        clickat -406 20
        sidebutton 3
        sidebutton 3 0.4 80 6 12
        windowtop
        waitfile /tmp/pd-step
        waitfile /tmp/pd-step 5
        """)
        XCTAssertEqual(actions, [
            .hoverAt(dx: 0, top: 200),
            .clickAt(dx: -406, top: 20),
            .sideButton(3, hold: 0.08, dx: 0, dy: 0, steps: 0),
            .sideButton(3, hold: 0.4, dx: 80, dy: 6, steps: 12),
            .windowTop,
            .waitFile("/tmp/pd-step", timeout: 30),
            .waitFile("/tmp/pd-step", timeout: 5),
        ])
        for bad in ["hoverat 1", "clickat a b", "sidebutton", "sidebutton 1", "sidebutton 3 0.4 80",
                    "windowtop now", "waitfile relative/path", "waitfile"] {
            XCTAssertThrowsError(try DebugInputScript.parse(bad), bad)
        }
    }

    func testDensityVerb() throws {
        XCTAssertEqual(try DebugInputScript.parse("density com.example.app 125"),
                       [.density(pkg: "com.example.app", value: 1.25)])
        XCTAssertEqual(try DebugInputScript.parse("density com.example.app default"),
                       [.density(pkg: "com.example.app", value: nil)])
        for bad in ["density", "density com.example.app", "density com.example.app sideways"] {
            XCTAssertThrowsError(try DebugInputScript.parse(bad), bad)
        }
    }

    func testWindowPointIsFromTheCentreAndTheTopEdge() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        XCTAssertEqual(DebugInputDriver.windowPoint(dx: -406, top: 20, in: window), CGPoint(x: 44, y: 580))
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
        XCTAssertThrowsError(try DebugInputScript.parse("showtouches"))
        XCTAssertThrowsError(try DebugInputScript.parse("strip on"), "the title strip is gone")
        XCTAssertThrowsError(try DebugInputScript.parse("fingerpinch 0.5 0.5 2 -1"))
        XCTAssertThrowsError(try DebugInputScript.parse("pinch 0.5 0.5 2 3"))
        XCTAssertThrowsError(try DebugInputScript.parse("hover 0.5"))
        XCTAssertThrowsError(try DebugInputScript.parse("notifyclick"))
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd"))
        XCTAssertThrowsError(try DebugInputScript.parse("mediacmd rewind"))
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
