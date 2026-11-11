// The bar's controls (docs/design/mac-redesign.md "Bar controls"): which
// actions share a capsule, the symbols, the Live Text freeze, and the contrast
// of the symbols over white, black and busy frames. All pure except the
// off-screen render, which draws the real HeaderBarView.

import AppKit
import XCTest
@testable import Contigua

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
            XCTAssertFalse(HeaderActionPolicy.isEnabled(kind, frozen: true), "\(kind) must be frozen")
        }
        XCTAssertTrue(HeaderActionPolicy.isEnabled(.liveText, frozen: true))
    }

    func testOutsideTheModeEverythingIsEnabled() {
        for kind in HeaderActionKind.allCases {
            XCTAssertTrue(HeaderActionPolicy.isEnabled(kind, frozen: false))
        }
        XCTAssertTrue(HeaderActionPolicy.allowsPhoneShortcut(frozen: false))
        XCTAssertFalse(HeaderActionPolicy.allowsPhoneShortcut(frozen: true))
    }

    /// A link that is down disables every phone-side control, Live Text
    /// included in nothing: its own button stays live (M3, item 8).
    func testADownLinkDisablesEveryPhoneControlButLiveText() {
        for kind in HeaderActionKind.allCases where kind != .liveText {
            XCTAssertFalse(HeaderActionPolicy.isEnabled(kind, frozen: false, offline: true),
                           "\(kind) must be dimmed while the link is down")
            XCTAssertFalse(HeaderActionPolicy.isEnabled(kind, frozen: true, offline: true), "\(kind)")
        }
        XCTAssertTrue(HeaderActionPolicy.isEnabled(.liveText, frozen: false, offline: true))
        XCTAssertFalse(HeaderActionPolicy.allowsPhoneShortcut(frozen: false, offline: true))
    }

    /// The reason names the next step, and the bar really dims: a frozen or
    /// offline button is not clickable (item 8/item 9).
    @MainActor
    func testTheBarDimsAndCarriesTheOfflineReason() {
        let bar = HeaderBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let back = HeaderAction.back {}
        let panel = HeaderAction(kind: .custom, customSymbol: "iphone",
                                 help: "Turn Off Phone Screen") {}
        bar.setActions([back, panel], liveTextActive: false)
        XCTAssertEqual(bar.enabledKinds, ["back", "custom"])
        XCTAssertEqual(panel.offlineReason, "Connect your phone to turn off its screen.")
        XCTAssertEqual(back.offlineReason, "Connect your phone to use these.")

        bar.setOffline(true)
        XCTAssertEqual(bar.enabledKinds, [], "no phone-side control is live offline")
        XCTAssertFalse(bar.button(for: .custom)?.isEnabled ?? true)
        XCTAssertEqual(bar.button(for: .custom)?.disabledReason,
                       "Connect your phone to turn off its screen.")
        XCTAssertEqual(bar.button(for: .back)?.disabledReason, "Connect your phone to use these.")

        bar.setOffline(false)
        XCTAssertEqual(bar.enabledKinds, ["back", "custom"])
        XCTAssertNil(bar.button(for: .custom)?.disabledReason)
    }
}

/// Off-screen render of the real bar over the frames the person sees through
/// it. The symbols must keep at least 3:1 against the capsule they sit on
/// (AGENTS.md Testing rules, contrast).
@MainActor
final class BarContrastTests: XCTestCase {
    private let barWidth: CGFloat = 900
    private let barHeight = HeaderBar.buttonHeight

    private func actions() -> [HeaderAction] {
        [.back {}, .home {}, .recents {}]
    }

    private func render(kind: NFRBackdropView.Kind, material: HeaderBar.Material,
                        symbols: Bool) -> NSBitmapImageRep {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: barWidth, height: barHeight))
        let backdrop = NFRBackdropView(kind: kind, frame: container.bounds)
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
        return NFROffscreen.render(container, size: container.bounds.size)
    }

    /// The glyph's own pixels in the mask render: magenta, not the capsule or
    /// the frame behind it (anti-aliased edges are left out).
    private func isMaskColor(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else { return false }
        return srgb.redComponent > 0.5 && srgb.blueComponent > 0.5 && srgb.greenComponent < 0.35
    }

    private func assertContrast(_ dark: Bool, backdrop: NFRBackdropView.Kind,
                                file: StaticString = #filePath, line: UInt = #line) {
        let material = HeaderBar.material(dark: dark)
        // The glyph mask comes from a render with an unmistakable ink (so the
        // mask exists even when the real symbol would vanish into the frame);
        // the contrast is then measured with the symbol colour that ships.
        var maskMaterial = material
        maskMaterial.symbol = .magenta
        let masked = render(kind: backdrop, material: maskMaterial, symbols: true)
        let bare = render(kind: backdrop, material: material, symbols: false)
        let inkLum = NFRContrast.relativeLuminance(material.symbol)
        var worst = Double.infinity
        var inkPixels = 0
        for x in 0..<masked.pixelsWide {
            for y in 0..<masked.pixelsHigh {
                guard let mask = masked.colorAt(x: x, y: y), let background = bare.colorAt(x: x, y: y),
                      isMaskColor(mask) else { continue }
                inkPixels += 1
                worst = min(worst, NFRContrast.ratio(inkLum, NFRContrast.relativeLuminance(background)))
            }
        }
        XCTAssertGreaterThan(inkPixels, 40, "the render drew no symbols", file: file, line: line)
        let required = NFRTestLimits.shared.double("contrast_min")
        XCTAssertGreaterThanOrEqual(worst, required,
            "\(dark ? "dark" : "light") appearance over \(backdrop): worst symbol contrast \(worst):1, wanted \(required):1",
            file: file, line: line)
    }

    func testSymbolsKeepThreeToOneOverWhiteBlackAndBusyFrames() {
        for dark in [false, true] {
            for backdrop in [NFRBackdropView.Kind.white, .black, .busy] {
                assertContrast(dark, backdrop: backdrop)
            }
        }
    }
}

/// The bar's material comes from the window's appearance as soon as the chrome
/// is in a window, not only on a later change: a window created in Dark kept a
/// light bar until something changed the system appearance (the capture in
/// `.agent/conv-fixes-1/bar-focus.png`).
@MainActor
final class BarAppearanceTests: XCTestCase {
    private func chrome(in appearance: NSAppearance?) -> (NSWindow, StreamChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let chrome = StreamChromeView(video: VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780)),
                                      style: .immersive)
        chrome.frame = NSRect(x: 0, y: 0, width: 380, height: 800)
        window.contentView = chrome
        return (window, chrome)
    }

    func testADarkWindowGetsTheDarkBarWhenTheChromeLands() {
        let (window, chrome) = chrome(in: NSAppearance(named: .darkAqua))
        XCTAssertEqual(chrome.barMaterial, HeaderBar.material(dark: true))
        window.close()
    }

    func testALightWindowGetsTheLightBar() {
        let (window, chrome) = chrome(in: NSAppearance(named: .aqua))
        XCTAssertEqual(chrome.barMaterial, HeaderBar.material(dark: false))
        window.close()
    }
}
