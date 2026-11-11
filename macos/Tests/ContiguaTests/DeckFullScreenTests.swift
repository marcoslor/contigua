// The Deck's native full screen (DECK-25): the window fills the screen, and
// its header — the toolbar with the connection chip and title — is the Deck's
// own, not the system's toolbar strip pinned across the top.
//
// In native full screen AppKit keeps an NSToolbarFullScreenWindow across the
// top of the screen for the whole session unless the window's presentation
// options auto-hide the toolbar. That strip is the band the person saw above
// the Deck (the window opens below it) and the host of the floating
// "Connecting…" chip — over the header title instead of in the header. The
// Deck's window delegate answers the options; these tests pin what it answers.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class DeckFullScreenTests: XCTestCase {
    private let optionsSelector =
        #selector(NSWindowDelegate.window(_:willUseFullScreenPresentationOptions:))

    /// The Deck's delegate opts the full-screen session out of the pinned
    /// toolbar strip: the toolbar auto-hides with the menu bar, so the window
    /// fills the screen and the header comes down from the top edge as it does
    /// in a window (the chip stays in it).
    func testTheDeckHidesTheSystemsToolbarStripWithTheMenuBar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let proxy = DeckWindowDelegate()
        guard proxy.responds(to: optionsSelector) else {
            XCTFail("""
                the Deck's window delegate must answer the full-screen presentation options; \
                without them AppKit pins its toolbar strip across the top (the band above \
                the Deck and the chip over the header)
                """)
            return
        }
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideDock]
        let fullScreen = proxy as NSWindowDelegate
        guard let options = fullScreen.window?(window, willUseFullScreenPresentationOptions: proposed) else {
            XCTFail("""
                the Deck's window delegate must answer the full-screen presentation options; \
                without them AppKit pins its toolbar strip across the top (the band above \
                the Deck and the chip over the header)
                """)
            return
        }
        XCTAssertTrue(options.contains(.autoHideToolbar), "the toolbar strip auto-hides")
        XCTAssertTrue(options.contains(.autoHideMenuBar), "with the menu bar, as a full-screen app's do")
        XCTAssertTrue(options.contains(.fullScreen), "the session is still full screen")
        XCTAssertTrue(options.contains(.autoHideDock), "and keeps what the system proposed")
    }

    /// SwiftUI's own delegate may propose its options: the Deck merges them
    /// with the auto-hide rather than replacing them.
    func testTheDecksOptionsKeepWhatTheSystemProposed() {
        final class Stub: NSObject, NSWindowDelegate {
            func window(_ window: NSWindow,
                        willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions)
                -> NSApplication.PresentationOptions {
                proposed.union([.disableProcessSwitching])
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let stub = Stub()
        let proxy = DeckWindowDelegate()
        proxy.target = stub
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideDock]
        let options = (proxy as NSWindowDelegate).window?(window, willUseFullScreenPresentationOptions: proposed) ?? []
        XCTAssertTrue(options.contains(.disableProcessSwitching), "the system's own options survive")
        XCTAssertTrue(options.contains(.autoHideToolbar))
        XCTAssertTrue(options.contains(.autoHideMenuBar))
    }
}
