// ⌥⌘F, the window's style shortcut (View ▸ Framed/Immersive). The menu pair
// carries it for display, but a disabled item does not consume its key
// equivalent: with no stream window key when the commands were built, the key
// arrives at the window, which must switch the style itself — and must never
// forward it to the phone as ⌘F.

import AppKit
import XCTest
@testable import Contigua

final class StyleShortcutTests: XCTestCase {
    private var mapper: InputMapper!
    private var commands: [InputMapper.Command] = []
    private var toggles = 0

    override func setUp() {
        super.setUp()
        mapper = InputMapper(stream: 1)
        commands = []
        toggles = 0
        mapper.send = { [weak self] command in self?.commands.append(command) }
        mapper.onStyleToggle = { [weak self] in self?.toggles += 1 }
    }

    func testOptionCommandFTogglesTheStyleAndNeverReachesThePhone() {
        mapper.keyDown(keyEvent("f", code: InputMapper.keyCodeF, flags: [.command, .option]))
        XCTAssertEqual(toggles, 1)
        XCTAssertTrue(commands.isEmpty, "⌥⌘F reached the phone: \(commands)")

        mapper.keyUp(keyEvent("f", code: InputMapper.keyCodeF, flags: [.command, .option]))
        XCTAssertTrue(commands.isEmpty)
    }

    /// ⌘F belongs to the phone (CONV-MAC-01) and still does.
    func testCommandFStillReachesThePhone() {
        mapper.keyDown(keyEvent("f", code: InputMapper.keyCodeF, flags: [.command]))
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(commands.count, 1, "⌘F must reach the phone")
    }

    private func keyEvent(_ characters: String, code: UInt16,
                          flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code)!
    }
}
