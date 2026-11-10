// CONV-PD-07 one name, and the Mac's own case rules: the pair-again action in
// a banner is sentence case without an ellipsis ("Pair again"), and only a
// menu or button title that opens the pairing sheet is title case with one
// ("Pair Again…"). The phone's own "Pair new Mac" is the phone's.

import Foundation
import XCTest
@testable import PocketDeck

final class PairAgainCopyTests: XCTestCase {
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")

    /// The two spellings, and the one helper that picks which a control shows.
    func testThePairAgainActionHasOneSpellingPerSurface() {
        XCTAssertEqual(PairAgainCopy.banner, "Pair again")
        XCTAssertEqual(PairAgainCopy.sheet, "Pair Again…")
        XCTAssertEqual(PairAgainCopy.sheetButton(needsPairing: true), "Pair Again…")
        XCTAssertEqual(PairAgainCopy.sheetButton(needsPairing: false), "Pair")
    }

    /// Every Mac surface that offers the action reads one of the two spellings.
    func testEverySurfaceUsesTheOneSpellingForItsKind() {
        // A banner: sentence case, no ellipsis.
        XCTAssertEqual(Banner(text: "Pixel 9 no longer trusts this Mac.",
                              action: .pairAgain).actionTitle, "Pair again")
        // State words beside a dot or in a row.
        XCTAssertEqual(Link.needsPairing(phone).chip?.text, "Pair again")
        XCTAssertEqual(PhoneControlsState.Connection.needsPairing.text, "Pair again")
        XCTAssertEqual(DevicePresence.pairAgain.text, "Pair again")
        // A button that opens the sheet: title case with the ellipsis.
        XCTAssertEqual(PhonePageHeaderAction.pairAgain.title, "Pair Again…")
        XCTAssertEqual(PairAgainCopy.sheetButton(needsPairing: true), PhonePageHeaderAction.pairAgain.title)
    }

    /// Nothing in the Mac sources spells the action its own way: the two
    /// literals live in `PairAgainCopy` alone, so a new surface cannot start a
    /// third spelling.
    func testNoMacSourceCarriesItsOwnPairAgainLiteral() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PocketDeck", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no Mac sources found at \(sources.path)")
        for file in files where file.lastPathComponent != "Link.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = Self.withoutComments(text)
            XCTAssertFalse(code.contains("\"Pair again\""),
                           "\(file.lastPathComponent) spells the banner action itself")
            XCTAssertFalse(code.contains("\"Pair Again…\""),
                           "\(file.lastPathComponent) spells the sheet action itself")
        }
    }

    /// The source without its comments: a doc comment may name the copy
    /// without being a second spelling of it.
    private static func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quotes = 0
            var index = line.startIndex
            while index < line.endIndex {
                if line[index] == "\"" { quotes += 1 }
                if line[index] == "/", line.index(after: index) < line.endIndex,
                   line[line.index(after: index)] == "/", quotes % 2 == 0 {
                    return String(line[line.startIndex..<index])
                }
                index = line.index(after: index)
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
