// The shared cover rule (ISS-55, ISS-66): every full-window cover wraps its
// words, wears the held picture blurred and darkened (a gradient or black when
// there is none) and never a flat grey, reaches under the titlebar and keeps
// its text and button label at WCAG AA in both appearances. These checks run
// against every cover in the inventory, not one view.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class CoverRuleTests: XCTestCase {
    private func makeVideo(_ width: CGFloat, _ height: CGFloat) -> VideoLayerView {
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        video.setVideoSizeForTesting(CGSize(width: width, height: height))
        return video
    }

    private func makeChrome(width: CGFloat, height: CGFloat) -> StreamChromeView {
        let chrome = StreamChromeView(video: makeVideo(width, height), style: .framed)
        chrome.frame = NSRect(x: 0, y: 0, width: width, height: height + ChromeBar.height)
        chrome.layoutChrome()
        return chrome
    }

    /// The four window kinds share the app/link/handoff opening cover and the
    /// stall overlay; the phone window's minimum is its bar's own rule.
    private var minimumWidths: [(String, CGFloat)] {
        let phone = max(240, HeaderBar.minimumWidth(for: [
            .back {}, .home {}, .recents {},
            HeaderAction(kind: .custom, customSymbol: "iphone", help: "Turn Off Phone Screen") {},
        ]))
        return [("app", 320), ("phone", phone)]
    }

    private func shows(_ chrome: StreamChromeView, state: String) {
        switch state {
        case "screen-off":
            chrome.phoneOverlay.show(.screenOff)
        case "secure":
            chrome.phoneOverlay.show(.secure)
        case "opening":
            chrome.openingCover.show(OpeningCover.display(.opening, name: "Settings", phone: "Pixel 9 Pro Fold",
                                                           phoneMode: false), icon: nil)
        case "slow":
            chrome.openingCover.show(OpeningCover.display(.slow, name: "Settings", phone: "Pixel 9 Pro Fold",
                                                           phoneMode: false), icon: nil)
        case "failed":
            chrome.openingCover.show(OpeningCover.display(.failed(reason: "This phone can't share its screen with PocketDeck."),
                                                           name: "Settings", phone: "Pixel 9 Pro Fold",
                                                           phoneMode: false), icon: nil)
        case "stalled":
            chrome.stallOverlay.show(StallOverlayDisplay(kind: .stalled, phone: "Pixel 9 Pro Fold"), icon: nil)
        case "reconnecting":
            chrome.stallOverlay.show(StallOverlayDisplay(kind: .reconnecting, phone: "Pixel 9 Pro Fold"), icon: nil)
        case "offline":
            chrome.stallOverlay.show(StallOverlayDisplay(kind: .offline, phone: "Pixel 9 Pro Fold"), icon: nil)
        default:
            XCTFail("unknown cover state \(state)")
        }
        chrome.layoutChrome()
        chrome.layoutSubtreeIfNeeded()
    }

    private func cover(_ chrome: StreamChromeView, state: String) -> NSView {
        switch state {
        case "screen-off", "secure": return chrome.phoneOverlay
        case "opening", "slow", "failed": return chrome.openingCover
        default: return chrome.stallOverlay
        }
    }

    private let states = ["screen-off", "secure", "opening", "slow", "failed",
                          "stalled", "reconnecting", "offline"]

    private func labels(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        for sub in view.subviews {
            // `NSTextField` only: a button's title is not a wrapping label.
            if type(of: sub) == NSTextField.self, let label = sub as? NSTextField,
               !label.isHidden, !label.stringValue.isEmpty {
                found.append(label)
            }
            found.append(contentsOf: labels(in: sub))
        }
        return found
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        for sub in view.subviews {
            if let button = sub as? NSButton, !button.isHidden { found.append(button) }
            found.append(contentsOf: buttons(in: sub))
        }
        return found
    }

    // MARK: Every cover's words fit, wrapped, never cut

    func testEveryCoverWrapsItsTextAtTheMinimumWidth() {
        var checked = 0
        for (kind, width) in minimumWidths {
            for state in states {
                if kind == "app", state == "screen-off" || state == "secure" { continue }
                if kind == "phone", state == "stalled" || state == "reconnecting" || state == "offline" { continue }
                let chrome = makeChrome(width: width, height: 650)
                shows(chrome, state: state)
                let view = cover(chrome, state: state)
                for label in labels(in: view) {
                    checked += 1
                    let name = "\(kind) \(state) \"\(label.stringValue)\""
                    XCTAssertEqual(label.lineBreakMode, .byWordWrapping,
                                   "\(name): the label must wrap, not truncate")
                    XCTAssertTrue(label.cell?.wraps == true, "\(name): the cell does not wrap")
                    XCTAssertTrue(label.maximumNumberOfLines == 0 || label.maximumNumberOfLines <= 3,
                                  "\(name): at most three lines at the narrowest window")
                    let available = label.bounds.width
                    XCTAssertGreaterThan(available, 100, "\(name): the label has no width")
                    let font = label.font ?? NSFont.systemFont(ofSize: 13)
                    let unwrapped = (label.stringValue as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertLessThanOrEqual(unwrapped, available * 3 + 1,
                                             "\(name): \(Int(unwrapped)) pt of text does not fit three lines of \(Int(available)) pt")
                    let needed = label.sizeThatFits(NSSize(width: available, height: .greatestFiniteMagnitude))
                    XCTAssertLessThanOrEqual(needed.width, available + 1, "\(name): the words overflow their width")
                    XCTAssertLessThanOrEqual(needed.height, font.boundingRectForFont.height * 3 + 2,
                                             "\(name): the words need more than three lines")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 8, "every cover's text was measured")
    }

    // MARK: Never a flat grey; the held picture, a gradient or black; one sheet

    /// A full-size flat fill that is not black: the grey material or ground the
    /// person reported. A held-picture backdrop carries `contents`, a gradient
    /// carries its colours, black carries a black fill; none of them is a grey.
    private func flatGrey(in view: NSView, bounds: NSRect) -> String? {
        let full = bounds.width * bounds.height > 0
            ? view.frame.width >= bounds.width * 0.9 && view.frame.height >= bounds.height * 0.9
            : true
        if full, let effect = view as? NSVisualEffectView, !effect.isHidden {
            return "a \(effect.material) visual-effect material"
        }
        if full, let color = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
           color.alphaComponent > 0.6, color.brightness > 0.08, color.brightness < 0.92 {
            return "a flat \(String(format: "%.2f", color.brightness)) fill"
        }
        for layer in view.layer?.sublayers ?? [] {
            guard layer.frame.width >= bounds.width * 0.9, layer.frame.height >= bounds.height * 0.9 else { continue }
            if layer.contents != nil || layer is CAGradientLayer { continue }
            if let color = layer.backgroundColor.flatMap(NSColor.init(cgColor:)),
               color.alphaComponent > 0.6, color.brightness > 0.08, color.brightness < 0.92 {
                return "a flat \(String(format: "%.2f", color.brightness)) layer"
            }
        }
        for sub in view.subviews {
            if let grey = flatGrey(in: sub, bounds: bounds) { return grey }
        }
        return nil
    }

    private func backdropKind(in view: NSView) -> String? {
        for layer in view.layer?.sublayers ?? [] {
            if let name = layer.name, name.hasPrefix("frosted-cover.backdrop.") {
                return String(name.dropFirst("frosted-cover.backdrop.".count))
            }
            if let kind = backdropKind(layer) { return kind }
        }
        for sub in view.subviews {
            if let kind = backdropKind(in: sub) { return kind }
        }
        return nil
    }

    private func backdropKind(_ layer: CALayer) -> String? {
        for sub in layer.sublayers ?? [] {
            if let name = sub.name, name.hasPrefix("frosted-cover.backdrop.") {
                return String(name.dropFirst("frosted-cover.backdrop.".count))
            }
            if let kind = backdropKind(sub) { return kind }
        }
        return nil
    }

    func testEveryCoverIsTheHeldFrameOrAGradientNeverGrey() {
        for (kind, width) in minimumWidths {
            for state in states {
                if kind == "app", state == "screen-off" || state == "secure" { continue }
                if kind == "phone", state == "stalled" || state == "reconnecting" || state == "offline" { continue }
                let chrome = makeChrome(width: width, height: 650)
                shows(chrome, state: state)
                let view = cover(chrome, state: state)
                let name = "\(kind) \(state)"
                XCTAssertEqual(view.frame, chrome.bounds,
                               "\(name): the cover is one sheet over the whole window, the titlebar included")
                XCTAssertNil(flatGrey(in: view, bounds: view.bounds),
                             "\(name): a flat grey fill instead of the held picture")
                let backdrop = backdropKind(in: view)
                XCTAssertNotNil(backdrop, "\(name): no held-picture/gradient/black backdrop")
                XCTAssertTrue(["held", "gradient", "black"].contains(backdrop ?? ""),
                              "\(name): the backdrop is \(backdrop ?? "none")")
            }
        }
    }

    // MARK: AA contrast in both appearances, over a white and a black frame

    private func dimAlpha(in view: NSView, bounds: NSRect) -> CGFloat {
        var found: CGFloat = 0
        func inspect(_ layer: CALayer?) {
            guard let layer else { return }
            if layer.frame.width >= bounds.width * 0.9, layer.frame.height >= bounds.height * 0.9,
               let color = layer.backgroundColor.flatMap(NSColor.init(cgColor:)),
               color.alphaComponent > 0.2, color.brightness < 0.05 {
                found = max(found, color.alphaComponent)
            }
            (layer.sublayers ?? []).forEach(inspect)
        }
        inspect(view.layer)
        for sub in view.subviews {
            if sub.frame.width >= bounds.width * 0.9, sub.frame.height >= bounds.height * 0.9,
               let color = sub.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
               color.alphaComponent > 0.2, color.brightness < 0.05 {
                found = max(found, color.alphaComponent)
            }
            found = max(found, dimAlpha(in: sub, bounds: bounds))
        }
        return found
    }

    /// An opaque ground the cover paints itself (the opening cover's old dark
    /// sheet): white and black are only the frames under a translucent dim.
    private func opaqueGround(in view: NSView, bounds: NSRect) -> NSColor? {
        func inspect(_ layer: CALayer?) -> NSColor? {
            guard let layer else { return nil }
            if layer.frame.width >= bounds.width * 0.9, layer.frame.height >= bounds.height * 0.9,
               let color = layer.backgroundColor.flatMap(NSColor.init(cgColor:)),
               color.alphaComponent > 0.9, color.brightness > 0.03 {
                return color
            }
            for sub in layer.sublayers ?? [] {
                if let ground = inspect(sub) { return ground }
            }
            return nil
        }
        if let ground = inspect(view.layer) { return ground }
        for sub in view.subviews {
            if let color = sub.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
               sub.frame.width >= bounds.width * 0.9, sub.frame.height >= bounds.height * 0.9,
               color.alphaComponent > 0.9, color.brightness > 0.03 {
                return color
            }
            if let ground = opaqueGround(in: sub, bounds: bounds) { return ground }
        }
        return nil
    }

    private func ground(_ frame: NSColor, in view: NSView) -> NSColor {
        if let ground = opaqueGround(in: view, bounds: view.bounds) { return ground }
        let alpha = dimAlpha(in: view, bounds: view.bounds)
        return frame.blended(withFraction: alpha, of: .black) ?? frame
    }

    private func ink(_ color: NSColor?) -> NSColor { color ?? .white }

    func testEveryCoverKeepsItsTextAtAAContrastInBothAppearances() {
        var checked = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (kind, width) in minimumWidths {
                for state in states {
                    if kind == "app", state == "screen-off" || state == "secure" { continue }
                    if kind == "phone", state == "stalled" || state == "reconnecting" || state == "offline" { continue }
                    let chrome = makeChrome(width: width, height: 650)
                    chrome.appearance = NSAppearance(named: appearance)
                    shows(chrome, state: state)
                    let view = cover(chrome, state: state)
                    view.appearance = NSAppearance(named: appearance)
                    if let stall = view as? StallOverlayView { stall.applyAppearanceStyle() }
                    chrome.layoutChrome()
                    chrome.layoutSubtreeIfNeeded()
                    let name = "\(kind) \(state) \(appearance.rawValue)"
                    for frame in [NSColor.white, NSColor.black] {
                        let backing = ground(frame, in: view)
                        for label in labels(in: view) {
                            checked += 1
                            let ratio = StallOverlayStyle.contrast(ink(label.textColor), backing)
                            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                                        "\(name): \"\(label.stringValue)\" is \(String(format: "%.1f", ratio)):1")
                        }
                        for button in buttons(in: view) where !button.isHidden {
                            checked += 1
                            let title = button.attributedTitle
                            let color = title.length > 0
                                ? title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
                            XCTAssertNotNil(color, "\(name): \"\(button.title)\" has no explicit white label")
                            let ratio = StallOverlayStyle.contrast(ink(color), backing)
                            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                                        "\(name): the button \"\(button.title)\" is \(String(format: "%.1f", ratio)):1")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 8, "every cover's ink was measured")
    }
}

private extension NSColor {
    /// The colour's perceived brightness (0…1).
    var brightness: Double {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * Double(rgb.redComponent) + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }
}
