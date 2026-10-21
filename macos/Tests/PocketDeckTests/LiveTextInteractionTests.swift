// Live Text's real-control path (AGENTS.md "Drive the real control"): with a
// frame frozen and VisionKit's analysis on the overlay, the overlay must be the
// view the window's hit test finds at a recognised word (not the video view, a
// cover or the chrome), it must keep its supplementary Live Text button, and it
// must offer text selection. v104 set `selectableItemsHighlighted` on the first
// analysis and left `preferredInteractionTypes` at `.automatic`, whose
// resolved set has no text selection, so the person's drags selected nothing.
//
// The down/drag/up itself runs in the app (e2e `livetext`, the `drag-check`
// script action): an XCTest bundle has no NSApplication, so a window can never
// become key there and AppKit drops the activation click before VisionKit sees
// it. K2 pins the view tree and the interaction set; the quiet e2e's app is
// inactive too, so the selection itself is the person's (an active window).

import AppKit
import CoreVideo
import VisionKit
import XCTest
@testable import PocketDeck

@MainActor
final class LiveTextInteractionTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.livetext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    /// A white frame with one big word across the middle (what VisionKit reads).
    private func textFrame(_ word: String, offset: CGFloat = 0) -> (CVPixelBuffer, CGImage)? {
        let width = 1600, height = 800
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 200, weight: .bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.setFillColor(NSColor.black.cgColor)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 + offset,
                                       y: (CGFloat(height) - bounds.height) / 2)
        CTLineDraw(line, context)
        guard let image = LiveTextImage.cgImage(buffer) else { return nil }
        return (buffer, image)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func waitForShown(_ session: LiveTextSession, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if session.state == .shown { return true }
            pump(0.1)
        }
        return session.state == .shown
    }

    private func isOverlay(_ hit: NSView?, overlay: NSView) -> Bool {
        guard let hit else { return false }
        if hit === overlay { return true }
        return hit.isDescendant(of: overlay)
    }

    func testTheOverlayTakesAHitTestOnTextAndKeepsTextSelection() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        // The opening cover would swallow the hit test: this test is about the
        // frozen frame after its first frame.
        controller.noteFirstFrame()
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let session = try XCTUnwrap(controller.videoView.liveText)
        // VisionKit's analyser occasionally comes back with no results at all
        // on a loaded machine (the same frame reads "POCKETDECK" on the next
        // attempt); retry the freeze with a nudged frame, never the assertions.
        var sawText = false
        for attempt in 1...3 {
            let (buffer, image) = try XCTUnwrap(textFrame("POCKETDECK", offset: CGFloat(attempt * 9)))
            session.freeze(buffer, image: image, on: controller.videoView)
            XCTAssertTrue(waitForShown(session, timeout: 180),
                          "VisionKit never finished (state \(session.state))")
            if session.overlay.analysis?.hasResults(for: .text) == true {
                sawText = true
                break
            }
            if attempt < 3 {
                session.exit(.streamConfig)
                pump(0.5)
            }
        }

        let overlay = session.overlay
        XCTAssertFalse(overlay.isSupplementaryInterfaceHidden,
                       "the supplementary Live Text button must not be hidden")
        XCTAssertTrue(overlay.preferredInteractionTypes.contains(.textSelection),
                      "text selection must be an offered interaction (got \(overlay.preferredInteractionTypes.rawValue))")
        XCTAssertTrue(overlay.activeInteractionTypes.contains(.textSelection),
                      "VisionKit must resolve text selection as active (got \(overlay.activeInteractionTypes.rawValue))")

        // The overlay's own frame is the video rect. A hit over it must be the
        // overlay (or a VisionKit subview), never the video view that carries
        // the frozen picture: the drag has to reach VisionKit's machinery.
        let frame = overlay.convert(overlay.bounds, to: content)
        var videoHits = 0
        var overlayHits = 0
        stride(from: frame.minX + 8, to: frame.maxX - 8, by: 8).forEach { x in
            stride(from: frame.minY + 8, to: frame.maxY - 8, by: 8).forEach { y in
                let hit = content.hitTest(NSPoint(x: x, y: y))
                if isOverlay(hit, overlay: overlay) {
                    overlayHits += 1
                } else if hit === controller.videoView || hit?.isDescendant(of: controller.videoView) == true {
                    videoHits += 1
                }
            }
        }
        XCTAssertEqual(videoHits, 0, "the video view swallowed \(videoHits) points over the overlay")
        XCTAssertGreaterThan(overlayHits, 0, "no point over the frozen frame hit the overlay")

        // With recognised text, the hit at the word itself is the same route
        // the pointer takes (VisionKit lays its text views out after the
        // analysis callback, so pump while the scan finds nothing).
        guard sawText else {
            print("livetext test: VisionKit returned no text on this run; the overlay's frame route is pinned")
            return
        }
        var textPoint: NSPoint?
        let scanDeadline = Date(timeIntervalSinceNow: 15)
        repeat {
            stride(from: frame.minX + 8, to: frame.maxX - 8, by: 8).forEach { x in
                stride(from: frame.minY + 8, to: frame.maxY - 8, by: 8).forEach { y in
                    let point = NSPoint(x: x, y: y)
                    guard isOverlay(content.hitTest(point), overlay: overlay) else { return }
                    if overlay.hasText(at: overlay.convert(point, from: content)), textPoint == nil {
                        textPoint = point
                    }
                }
            }
            if textPoint == nil { pump(0.2) }
        } while textPoint == nil && Date() < scanDeadline
        let point = try XCTUnwrap(textPoint, "no point over the recognised word hit the overlay")
        let hit = try XCTUnwrap(content.hitTest(point))
        XCTAssertTrue(isOverlay(hit, overlay: overlay),
                      "a drag at recognised text must reach the overlay, not \(type(of: hit))")
    }
}
