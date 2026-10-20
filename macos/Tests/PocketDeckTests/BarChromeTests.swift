// The bar's controls (docs/design/mac-redesign.md "Bar controls"): which
// actions share a capsule, the symbols, the Live Text freeze, and the contrast
// of the symbols over white, black and busy frames. All pure except the
// off-screen render, which draws the real HeaderBarView.

import AppKit
import XCTest
@testable import PocketDeck

final class HeaderBarModelTests: XCTestCase {
    private func phoneActions() -> [HeaderAction] {
        [.back {}, .home {}, .recents {}]
    }

    func testThePhoneTrioSharesOneCapsule() {
        let groups = HeaderBar.groups(phoneActions())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.kind), [.back, .home, .recents])
    }

    func testTheCameraSwitchHasItsOwnCapsule() {
        let actions = phoneActions() + [.cameraSwitch {}]
        let groups = HeaderBar.groups(actions)
        XCTAssertEqual(groups.count, 2, "a different group starts a new capsule")
        XCTAssertEqual(groups[0].count, 3)
        XCTAssertEqual(groups[1].map(\.kind), [.cameraSwitch])
    }

    func testTheRowIsTheCapsulesAndTheGapsBetweenThem() {
        XCTAssertEqual(HeaderBar.rowWidth([]), 0)
        XCTAssertEqual(HeaderBar.rowWidth(phoneActions()), 3 * HeaderBar.buttonWidth)
        XCTAssertEqual(HeaderBar.rowWidth(phoneActions() + [.cameraSwitch {}]),
                       4 * HeaderBar.buttonWidth + HeaderBar.capsuleGap)
        XCTAssertEqual(HeaderBar.capsuleOrigins(phoneActions() + [.cameraSwitch {}]),
                       [0, 3 * HeaderBar.buttonWidth + HeaderBar.capsuleGap])
    }

    func testTheRowEndsAtTheRightInsetWithTheLiveTextCapsuleLast() {
        let row = HeaderBar.row(phoneActions(), rightEdge: 900)
        XCTAssertNotNil(row)
        XCTAssertEqual(row!.liveTextX, 900 - HeaderBar.rightInset - HeaderBar.liveTextSide)
        XCTAssertEqual(row!.actionsX + row!.actionsWidth + HeaderBar.capsuleGap, row!.liveTextX)
        XCTAssertEqual(row!.actionsX, 900 - HeaderBar.rightInset - row!.width)
    }

    func testTheSymbolsAreTheDesigns() {
        XCTAssertEqual(HeaderBar.symbol(for: .back), "chevron.backward")
        XCTAssertEqual(HeaderBar.symbol(for: .home), "house")
        XCTAssertEqual(HeaderBar.symbol(for: .recents), "rectangle.stack")
        XCTAssertEqual(HeaderBar.symbol(for: .liveText), "text.viewfinder")
        XCTAssertEqual(HeaderBar.symbol(for: .cameraSwitch), "arrow.triangle.2.circlepath.camera")
        let actions = phoneActions() + [.cameraSwitch {}]
        XCTAssertEqual(actions.map(\.symbol),
                       ["chevron.backward", "house", "rectangle.stack", "arrow.triangle.2.circlepath.camera"])
        XCTAssertEqual(actions.map(\.help), ["Back", "Home", "Recents", "Switch Camera"])
    }

    func testACustomActionKeepsItsOwnSymbol() {
        let action = HeaderAction(kind: .custom, customSymbol: "circle.grid.2x2", help: "Grid") {}
        XCTAssertEqual(action.symbol, "circle.grid.2x2")
        XCTAssertEqual(action.group, .custom("Grid"))
    }
}

final class HeaderActionPolicyTests: XCTestCase {
    func testLiveTextFreezesEveryKindButItsOwn() {
        for kind in HeaderActionKind.allCases where kind != .liveText {
            XCTAssertFalse(HeaderActionPolicy.isEnabled(kind, liveTextActive: true), "\(kind) must be frozen")
        }
        XCTAssertTrue(HeaderActionPolicy.isEnabled(.liveText, liveTextActive: true))
    }

    func testOutsideTheModeEverythingIsEnabled() {
        for kind in HeaderActionKind.allCases {
            XCTAssertTrue(HeaderActionPolicy.isEnabled(kind, liveTextActive: false))
        }
        XCTAssertTrue(HeaderActionPolicy.allowsPhoneShortcut(liveTextActive: false))
        XCTAssertFalse(HeaderActionPolicy.allowsPhoneShortcut(liveTextActive: true))
    }
}

/// Off-screen render of the real bar over the frames the person sees through
/// it. The symbols must keep at least 3:1 against the capsule they sit on
/// (AGENTS.md Testing rules, contrast).
@MainActor
final class BarContrastTests: XCTestCase {
    private let barWidth: CGFloat = 900
    private let barHeight = HeaderBar.buttonHeight

    private final class BackdropView: NSView {
        enum Kind { case white, black, busy }
        let kind: Kind
        init(kind: Kind, frame: NSRect) {
            self.kind = kind
            super.init(frame: frame)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            switch kind {
            case .white:
                NSColor.white.setFill()
                bounds.fill()
            case .black:
                NSColor.black.setFill()
                bounds.fill()
            case .busy:
                // Saturated quadrants and stripes: the bright, noisy frame that
                // made bare symbols disappear.
                let colors: [NSColor] = [.white, .black, .systemRed, .systemCyan, .systemYellow, .systemBlue]
                let w = bounds.width / CGFloat(colors.count)
                for (index, color) in colors.enumerated() {
                    color.setFill()
                    NSRect(x: CGFloat(index) * w, y: 0, width: w, height: bounds.height).fill()
                }
                NSColor.white.setFill()
                for x in stride(from: 0, to: bounds.width, by: 12) {
                    NSRect(x: x, y: 0, width: 3, height: bounds.height).fill()
                }
            }
        }
    }

    private func actions() -> [HeaderAction] {
        [.back {}, .home {}, .recents {}]
    }

    private func render(kind: BackdropView.Kind, material: HeaderBar.Material,
                        symbols: Bool) -> NSBitmapImageRep {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: barHeight))
        let backdrop = BackdropView(kind: kind, frame: container.bounds)
        container.addSubview(backdrop)
        let width = HeaderBar.rowWidth(actions())
        let bar = HeaderBarView(frame: NSRect(x: barWidth - HeaderBar.rightInset - width, y: 0,
                                              width: width, height: barHeight))
        bar.material = material
        bar.setActions(actions(), liveTextActive: false)
        if !symbols {
            // The same capsules and geometry, without the glyphs: what the
            // symbols sit on.
            bar.subviews.compactMap { $0 as? HeaderActionButton }.forEach { $0.removeFromSuperview() }
        }
        container.addSubview(bar)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            fatalError("no bitmap")
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    private func luminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

    /// The glyph's own pixels in the mask render: magenta, not the capsule or
    /// the frame behind it (anti-aliased edges are left out).
    private func isMaskColor(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else { return false }
        return srgb.redComponent > 0.5 && srgb.blueComponent > 0.5 && srgb.greenComponent < 0.35
    }

    private func ratio(_ a: Double, _ b: Double) -> Double {
        let high = max(a, b), low = min(a, b)
        return (high + 0.05) / (low + 0.05)
    }

    private func assertContrast(_ dark: Bool, backdrop: BackdropView.Kind,
                                file: StaticString = #filePath, line: UInt = #line) {
        let material = HeaderBar.material(dark: dark)
        // The glyph mask comes from a render with an unmistakable ink (so the
        // mask exists even when the real symbol would vanish into the frame);
        // the contrast is then measured with the symbol colour that ships.
        var maskMaterial = material
        maskMaterial.symbol = .magenta
        let masked = render(kind: backdrop, material: maskMaterial, symbols: true)
        let bare = render(kind: backdrop, material: material, symbols: false)
        let inkLum = luminance(material.symbol)
        var worst = Double.infinity
        var inkPixels = 0
        for x in 0..<masked.pixelsWide {
            for y in 0..<masked.pixelsHigh {
                guard let mask = masked.colorAt(x: x, y: y), let background = bare.colorAt(x: x, y: y),
                      isMaskColor(mask) else { continue }
                inkPixels += 1
                worst = min(worst, ratio(inkLum, luminance(background)))
            }
        }
        XCTAssertGreaterThan(inkPixels, 40, "the render drew no symbols", file: file, line: line)
        XCTAssertGreaterThanOrEqual(worst, 3.0,
            "\(dark ? "dark" : "light") appearance over \(backdrop): worst symbol contrast \(worst):1",
            file: file, line: line)
    }

    func testSymbolsKeepThreeToOneOverWhiteBlackAndBusyFrames() {
        for dark in [false, true] {
            for backdrop in [BackdropView.Kind.white, .black, .busy] {
                assertContrast(dark, backdrop: backdrop)
            }
        }
    }
}
