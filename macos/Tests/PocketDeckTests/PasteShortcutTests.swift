// ⌘V in a stream window: the pasteboard's text goes to the phone, but a file
// copy is consumed, never typed as its file's name (SHARE-2).

import AppKit
import XCTest
@testable import PocketDeck

final class PasteShortcutTests: XCTestCase {

    private final class StubPasteboard: PasteboardReader {
        var value: String?
        var fileCopy = false
        var files: [URL] = []
        var picture: (data: Data, mime: String)?
        func text() -> String? { value }
        func isFileCopy() -> Bool { fileCopy }
        func fileURLs() -> [URL] { files }
        func image() -> (data: Data, mime: String)? { picture }
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

    func testCommandVWithAFileCopyGoesToTheDropPath() {
        let board = StubPasteboard()
        board.value = "report.pdf"
        board.fileCopy = true
        board.files = [URL(fileURLWithPath: "/tmp/report.pdf")]
        let (map, sent) = mapper(board)
        var pasted: PasteboardPaste?
        map.onPaste = { paste in pasted = paste; return true }
        map.keyDown(keyEvent(9, "v", flags: [.command]))
        XCTAssertEqual(pasted, .files([URL(fileURLWithPath: "/tmp/report.pdf")]))
        XCTAssertEqual(sent(), [], "a Finder copy must not type its file's name into the phone")
    }

    func testCommandVWithAnImageGoesToThePasteFlow() {
        let board = StubPasteboard()
        board.picture = (Data([0x89, 0x50, 0x4E, 0x47]), "image/png")
        let (map, sent) = mapper(board)
        var pasted: PasteboardPaste?
        map.onPaste = { paste in pasted = paste; return true }
        map.keyDown(keyEvent(9, "v", flags: [.command]))
        XCTAssertEqual(pasted, .image(Data([0x89, 0x50, 0x4E, 0x47]), "image/png"))
        XCTAssertEqual(sent(), [], "an image is pasted as a clip image, not typed")
    }

    func testCommandVWithTextNextToAnImageTypesTheText() {
        let board = StubPasteboard()
        board.value = "pasted text"
        board.picture = (Data([1, 2, 3]), "image/png")
        let (map, sent) = mapper(board)
        var pasted: PasteboardPaste?
        map.onPaste = { pasted = $0; return true }
        map.keyDown(keyEvent(9, "v", flags: [.command]))
        XCTAssertNil(pasted, "a text item always takes the text path (SHARE-2)")
        XCTAssertEqual(sent(), [.text("pasted text")])
    }

    func testShiftCommandVSharesInsteadOfPasting() {
        let board = StubPasteboard()
        board.picture = (Data([1, 2, 3]), "image/png")
        let (map, sent) = mapper(board)
        var shared: PasteboardPaste?
        var pasted: PasteboardPaste?
        map.onShareInstead = { shared = $0 }
        map.onPaste = { pasted = $0; return true }
        map.keyDown(keyEvent(9, "v", flags: [.command, .shift]))
        XCTAssertEqual(shared, .image(Data([1, 2, 3]), "image/png"))
        XCTAssertNil(pasted)
        XCTAssertEqual(sent(), [])
    }
}
