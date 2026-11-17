// MCP-100/MCP-101 (plan T12): an agent's new window takes the phone's shape,
// and the person's own resize or density change hands it back for good.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class AgentWindowShapeTests: XCTestCase {
    private func encoder(align: Int) -> EncoderSpec {
        EncoderSpec(widthAlign: align, heightAlign: align, maxWidth: 4096, maxHeight: 4096,
                    maxPixelsAt60: 4096 * 2304)
    }

    private func shape(_ w: Int, _ h: Int, _ dpi: Int, align: Int = 2,
                       visible: CGSize = CGSize(width: 3000, height: 3000),
                       chrome: CGSize = .zero) -> AgentWindowShape? {
        AgentWindowShape.make(screenWidth: w, screenHeight: h, screenDpi: dpi,
                              encoder: encoder(align: align), visible: visible, chrome: chrome)
    }

    // MARK: Geometry (MCP-100)

    func testA1080x2340PhoneAt450Dpi_MCP100() throws {
        let two = try XCTUnwrap(shape(1080, 2340, 450, align: 2))
        XCTAssertEqual(two.pixels, CGSize(width: 590, height: 1280))
        XCTAssertEqual(two.dpi, 246)
        XCTAssertEqual(two.points, CGSize(width: 384, height: 832))
        let sixteen = try XCTUnwrap(shape(1080, 2340, 450, align: 16))
        XCTAssertEqual(sixteen.pixels, CGSize(width: 576, height: 1280))
        XCTAssertEqual(sixteen.dpi, 240)
        XCTAssertEqual(sixteen.points, CGSize(width: 384, height: 832))
    }

    func testA1440x3120PhoneAt600Dpi_MCP100() throws {
        let shape = try XCTUnwrap(shape(1440, 3120, 600, align: 2))
        XCTAssertEqual(shape.pixels, CGSize(width: 590, height: 1280))
        XCTAssertEqual(shape.dpi, 246)
        XCTAssertEqual(shape.points, CGSize(width: 384, height: 832))
    }

    func testALandscapeReportIsTurnedPortrait_MCP100() throws {
        XCTAssertEqual(try XCTUnwrap(shape(2340, 1080, 450)), try XCTUnwrap(shape(1080, 2340, 450)))
    }

    func testTheWindowFitsTheVisibleFrame_MCP100() throws {
        let shape = try XCTUnwrap(shape(1080, 2340, 450, visible: CGSize(width: 1280, height: 775),
                                        chrome: CGSize(width: 0, height: 43)))
        XCTAssertEqual(shape.points.height, 732)
        XCTAssertEqual(shape.points.width, 338)
        // The stream is still the phone's: the points only scale the picture.
        XCTAssertEqual(shape.pixels, CGSize(width: 590, height: 1280))
        XCTAssertEqual(shape.dpi, 246)
    }

    func testAPhoneWithNoScreenReportGetsNoShape_MCP100() {
        XCTAssertNil(shape(0, 0, 0))
    }

    // MARK: The hand-back machine (MCP-101): every transition

    func testThePersonsResizeHandsTheWindowBack_MCP101() {
        for event: AgentShapeHold.Event in [.personResize, .zoom, .tile, .fullScreen] {
            let (state, actions) = AgentShapeHold.step(.phone, event)
            XCTAssertEqual(state, .ordinary, "\(event)")
            XCTAssertEqual(actions, [.handBack], "\(event)")
        }
    }

    func testADensityChangeHandsTheWindowBack_MCP101() {
        let (state, actions) = AgentShapeHold.step(.phone, .densityChange)
        XCTAssertEqual(state, .ordinary)
        XCTAssertEqual(actions, [.handBack])
    }

    func testAMoveKeepsTheShape_MCP101() {
        let (state, actions) = AgentShapeHold.step(.phone, .move)
        XCTAssertEqual(state, .phone)
        XCTAssertEqual(actions, [])
    }

    func testARaiseKeepsTheShape_MCP101() {
        let (state, actions) = AgentShapeHold.step(.phone, .raise)
        XCTAssertEqual(state, .phone)
        XCTAssertEqual(actions, [])
    }

    func testAnOrdinaryWindowNeverReturnsToThePhoneShape_MCP101() {
        for event in AgentShapeHold.Event.allCases {
            let (state, actions) = AgentShapeHold.step(.ordinary, event)
            XCTAssertEqual(state, .ordinary, "\(event)")
            XCTAssertEqual(actions, [], "\(event)")
        }
    }

    // MARK: On a real window controller

    private var manager: WindowManager?
    private var defaults: UserDefaults?

    private func makeController() -> AppWindowController {
        let name = "app.contigua.tests.agentshape.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        let manager = WindowManager(session: session, defaults: defaults)
        self.manager = manager
        self.defaults = defaults
        return AppWindowController(stream: 1, pkg: "com.example.shop", activity: nil,
                                   label: "Shop", manager: manager)
    }

    func testAPhoneShapeWindowRemembersNoFrame_MCP100() throws {
        let controller = makeController()
        defer { controller.window?.close() }
        controller.takeAgentShape(try XCTUnwrap(shape(1080, 2340, 450)))
        XCTAssertFalse(controller.remembersFrame, "a phone-shape window writes no remembered frame")
        controller.agentShapeEvent(.move)
        XCTAssertFalse(controller.remembersFrame, "a move keeps the shape")
        controller.agentShapeEvent(.personResize)
        XCTAssertTrue(controller.remembersFrame, "handed back, WIN-13 applies")
        XCTAssertNil(controller.agentShape)
    }

    func testAPhoneShapeWindowIgnoresBothDensitySettings_MCP100() throws {
        let controller = makeController()
        defer { controller.window?.close() }
        let manager = try XCTUnwrap(manager)
        defaults?.set(1.5, forKey: WindowDensity.key)
        manager.densityStore.set(1.25, forKey: WindowDensityStore.key(forPackage: "com.example.shop"))
        controller.takeAgentShape(try XCTUnwrap(shape(1080, 2340, 450)))
        XCTAssertEqual(controller.dpi(), 246)
        XCTAssertEqual(controller.displayPixels(), CGSize(width: 590, height: 1280))
    }

    func testADensityPickOnThePhoneShapeWindowHandsItBack_MCP101() throws {
        let controller = makeController()
        defer { controller.window?.close() }
        controller.takeAgentShape(try XCTUnwrap(shape(1080, 2340, 450)))
        controller.applyStoredDensity()
        XCTAssertNil(controller.agentShape, "the person's density change hands the window back")
        XCTAssertNotEqual(controller.displayPixels(), CGSize(width: 590, height: 1280))
    }

    func testFullScreenHandsThePhoneShapeBack_MCP101() throws {
        let controller = makeController()
        defer { controller.window?.close() }
        controller.takeAgentShape(try XCTUnwrap(shape(1080, 2340, 450)))
        controller.simulateFullScreenForTesting(true)
        XCTAssertNil(controller.agentShape)
    }
}
