// The status item's drawing (MenuBar.swift): the symbol each link state draws,
// the template image the button owns, the agent dot drawn into that image, and
// every transition of the reconnecting pulse.

import XCTest
@testable import PocketDeck

final class MenuBarIconTests: XCTestCase {
    private let phone = PhoneRef(id: "phone-a", name: "Test Phone", model: "Pixel 9")

    private func link(_ state: MenuBarPulseTestLink) -> Link {
        switch state {
        case .idle: .idle
        case .connecting: .connecting(phone)
        case .online: .online(phone)
        case .reconnecting: .reconnecting(phone)
        case .offline: .offline(phone, .unreachable)
        case .needsPairing: .needsPairing(phone)
        case .pairing: .pairing(phone, .contacting)
        }
    }

    func testTheSymbolFollowsTheLink() {
        for state in MenuBarPulseTestLink.allCases {
            XCTAssertEqual(MenuBarGlyph.symbol(for: link(state)),
                           state == .offline ? "iphone.slash" : "apps.iphone",
                           "\(state)")
        }
    }

    func testTheImageIsAlwaysTheButtonsOwnTemplate() {
        for state in MenuBarPulseTestLink.allCases {
            for dot in [false, true] {
                for dimmed in [false, true] {
                    let image = MenuBarGlyph.image(link: link(state), dot: dot, dimmed: dimmed)
                    XCTAssertTrue(image.isTemplate, "\(state) dot=\(dot) dimmed=\(dimmed)")
                    XCTAssertGreaterThan(image.size.height, 0)
                }
            }
        }
    }

    func testTheDotWidensTheImageAndKeepsItsHeight() {
        let plain = MenuBarGlyph.image(link: .online(phone), dot: false)
        let withDot = MenuBarGlyph.image(link: .online(phone), dot: true)
        XCTAssertEqual(withDot.size.width, plain.size.width + MenuBarGlyph.dotGap + MenuBarGlyph.dotDiameter)
        XCTAssertEqual(withDot.size.height, plain.size.height)
    }

    func testTheDimFrameKeepsTheImagesSize() {
        let full = MenuBarGlyph.image(link: .reconnecting(phone), dot: false)
        let dim = MenuBarGlyph.image(link: .reconnecting(phone), dot: false, dimmed: true)
        XCTAssertEqual(dim.size, full.size)
        XCTAssertTrue(dim.isTemplate)
    }

    // MARK: The pulse machine

    private func assert(_ state: MenuBarPulseState, _ event: MenuBarPulseEvent,
                        becomes next: MenuBarPulseState, actions: [MenuBarPulseAction],
                        file: StaticString = #filePath, line: UInt = #line) {
        var machine = MenuBarPulseMachine()
        switch state {
        case .steady:
            break
        case .bright:
            _ = machine.handle(.pulses(true))
        case .dim:
            _ = machine.handle(.pulses(true))
            _ = machine.handle(.tick)
        }
        XCTAssertEqual(machine.handle(event), actions, "\(state) --\(event)-- actions",
                       file: file, line: line)
        XCTAssertEqual(machine.state, next, "\(state) --\(event)-- state", file: file, line: line)
    }

    func testAPulseStartsOnTheBrightFrameAndStopsBackAtSteady() {
        var machine = MenuBarPulseMachine()
        XCTAssertFalse(machine.isDim)
        XCTAssertEqual(machine.handle(.pulses(true)), [.show(dim: false), .startTimer])
        XCTAssertEqual(machine.state, .bright)
        XCTAssertEqual(machine.handle(.tick), [.show(dim: true)])
        XCTAssertTrue(machine.isDim)
        XCTAssertEqual(machine.handle(.tick), [.show(dim: false)])
        XCTAssertEqual(machine.state, .bright)
        XCTAssertEqual(machine.handle(.pulses(false)), [.show(dim: false), .stopTimer])
        XCTAssertEqual(machine.state, .steady)
    }

    func testEveryTransition() {
        let dim = [MenuBarPulseAction.show(dim: true)]
        let bright = [MenuBarPulseAction.show(dim: false)]
        let start: [MenuBarPulseAction] = [.show(dim: false), .startTimer]
        let stop: [MenuBarPulseAction] = [.show(dim: false), .stopTimer]
        assert(.steady, .pulses(false), becomes: .steady, actions: [])
        assert(.steady, .pulses(true), becomes: .bright, actions: start)
        assert(.steady, .tick, becomes: .steady, actions: [])
        assert(.bright, .pulses(true), becomes: .bright, actions: [])
        assert(.bright, .pulses(false), becomes: .steady, actions: stop)
        assert(.bright, .tick, becomes: .dim, actions: dim)
        assert(.dim, .pulses(true), becomes: .dim, actions: [])
        assert(.dim, .pulses(false), becomes: .steady, actions: stop)
        assert(.dim, .tick, becomes: .bright, actions: bright)
    }
}

/// The seven link states, so a test walks all of them. (`Link` itself carries
/// associated values, so the enum is the test's own closed list.)
enum MenuBarPulseTestLink: String, CaseIterable {
    case idle, connecting, online, reconnecting, offline, needsPairing, pairing
}
