// VisionKit's analyser (LiveTextView.swift) runs in a service of its own, and
// its text model is loaded on first use. On a loaded machine the first calls
// take tens of seconds and come back with no results at all: the person's v105
// log shows Live Text entered five times, two entries left again after 8–13 s
// without an analysis, and the rest reported 0 characters on a screen full of
// words. The warm-up below reads a word of our own until VisionKit answers
// with text, so the model is loaded before the person ever presses Live Text.
//
// Nothing here is shown or kept: the probe word is a fixture, never a person's
// content, and only the fact that the model answered is recorded.

import AppKit
import CoreGraphics
import Foundation
import VisionKit

enum LiveTextWarmer {
    /// True once an analysis of the probe read the probe word: text
    /// recognition is loaded and answering. Live Text does not depend on it
    /// (a cold service only costs time); the e2e check waits for it so its
    /// timing gate measures the service the person actually has.
    static var isWarm: Bool { state.isWarm }

    /// How long the warm-up keeps trying, and how often.
    static let deadline: TimeInterval = 120
    private static let interval: TimeInterval = 2

    private static let state = State()
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        Task.detached(priority: .utility) {
            let word = "POCKETDECK"
            let configuration = ImageAnalyzer.Configuration([.text])
            guard let probe = probeImage(word) else { return }
            let analyzer = ImageAnalyzer()
            let end = Date(timeIntervalSinceNow: deadline)
            while Date() < end {
                if let analysis = try? await analyzer.analyze(probe, orientation: .up,
                                                              configuration: configuration),
                   analysis.transcript.localizedCaseInsensitiveContains(word) {
                    state.markWarm()
                    Log.video.notice("livetext: the analyser is warm (probe read)")
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
            Log.video.error("livetext: the analyser stayed cold (probe never read)")
        }
    }

    /// A white card with one large black word: the cheapest picture that has
    /// to come back as text.
    private static func probeImage(_ word: String) -> CGImage? {
        let width = 480, height = 200
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2,
                                       y: (CGFloat(height) - bounds.height) / 2)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var warm = false

        var isWarm: Bool {
            lock.lock()
            defer { lock.unlock() }
            return warm
        }

        func markWarm() {
            lock.lock()
            warm = true
            lock.unlock()
        }
    }
}
