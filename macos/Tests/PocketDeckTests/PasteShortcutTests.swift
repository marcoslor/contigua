// ⌘V in a stream window: the pasteboard's text goes to the phone, but a file
// copy is consumed, never typed as its file's name (SHARE-2).

import AppKit
import XCTest
@testable import PocketDeck

final class PasteShortcutTests: XCTestCase {

    private final class StubPasteboard: PasteboardReader {
        var value: String?
        var fileCopy = false
        func text() -> String? { value }
        func isFileCopy() -> Bool { fileCopy }
    }

    private enum Sent: Equatable {
        case text(String)
        case key
        case nav
    }

    private func keyEvent(_ keyCode: UInt16, _ characters: String,
                          flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    private func mapper(_ board: StubPasteboard) -> (InputMapper, () -> [Sent]) {
        let mapper = InputMapper(stream: 1)
        var sent: [Sent] = []
        mapper.pasteboard = board
        mapper.send = { command in
            switch command {
            case .text(let text): sent.append(.text(text))
            case .key: sent.append(.key)
            case .nav: sent.append(.nav)
            case .touch, .scroll, .hover, .adjustDensity, .resetDensity: break
            }
        }
        return (mapper, { sent })
    }

    func testCommandVSendsPlainText() {
        let board = StubPasteboard()
        board.value = "pasted text"
        let (map, sent) = mapper(board)
        map.keyDown(keyEvent(9, "v", flags: [.command]))
        XCTAssertEqual(sent(), [.text("pasted text")])
    }

    func testCommandVWithAFileCopySendsNothing() {
        let board = StubPasteboard()
        board.value = "report.pdf"
        board.fileCopy = true
        let (map, sent) = mapper(board)
        map.keyDown(keyEvent(9, "v", flags: [.command]))
        XCTAssertEqual(sent(), [], "a Finder copy must not type its file's name into the phone")
    }
}
