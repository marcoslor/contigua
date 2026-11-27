// The bar's controls (docs/design/mac-redesign.md "Bar controls"): which
// actions share a capsule, the symbols, the Live Text freeze, and the contrast
// of the symbols over white, black and busy frames. All pure except the
// contrast pictures, which draw the real HeaderBarView in a window (off screen
// only where the window server cannot capture it).

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

/// The real bar over the frames the person sees through it: the symbols must
/// keep at least 3:1 against the capsule they sit on (WIN-22, MIRROR-22;
/// AGENTS.md Testing rules, contrast). Measured on screen, from the window
/// server's capture of a real window, so the glass and Reduce Transparency are
/// in the picture (#243: on macos-26 the off-screen render left the glass out
/// and read 19.66:1 where the screen showed 2.24:1). Where capture is
/// unavailable the test measures the off-screen render instead and says so.
@MainActor
final class BarContrastTests: XCTestCase {
    private let barWidth: CGFloat = 900
    private let barHeight = HeaderBar.buttonHeight
    /// Backdrop above and below each bar, so the glass at one frame's edge
    /// samples that frame and not the next one.
    private let rowPad: CGFloat = 24
    private let backdrops: [NFRBackdropView.Kind] = [.white, .black, .busy]

    private var rowHeight: CGFloat { barHeight + 2 * rowPad }
    private var stackSize: CGSize { CGSize(width: barWidth, height: CGFloat(backdrops.count) * rowHeight) }

    private func actions() -> [HeaderAction] {
        [.back {}, .home {}, .recents {}]
    }

    /// One row per backdrop, top to bottom, each with the real bar at its
    /// right end, as the chrome places it.
    private func stack(material: HeaderBar.Material, symbols: Bool) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: stackSize))
        for (index, kind) in backdrops.enumerated() {
            let y = stackSize.height - CGFloat(index + 1) * rowHeight
            container.addSubview(NFRBackdropView(kind: kind, frame: NSRect(x: 0, y: y, width: barWidth,
                                                                          height: rowHeight)))
            let width = HeaderBar.rowWidth(actions())
            let bar = HeaderBarView(frame: NSRect(x: barWidth - HeaderBar.rightInset - width, y: y + rowPad,
                                                  width: width, height: barHeight))
            bar.material = material
            bar.setActions(actions(), liveTextActive: false)
            if !symbols {
                // The same capsules and geometry, without the glyphs: what the
                // symbols sit on.
                bar.subviews.compactMap { $0 as? HeaderActionButton }.forEach { $0.removeFromSuperview() }
            }
            container.addSubview(bar)
        }
        return container
    }

    /// The glyph's own pixels in the mask render: magenta, not the capsule or
    /// the frame behind it (anti-aliased edges are left out).
    private func isMaskColor(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else { return false }
        return srgb.redComponent > 0.5 && srgb.blueComponent > 0.5 && srgb.greenComponent < 0.35
    }

    private struct Row {
        var worst = Double.infinity
        var inkPixels = 0
    }

    /// The shipped ink against what is under each glyph pixel in the
    /// symbol-less picture, one result per backdrop row.
    private func measure(masked: NSBitmapImageRep, bare: NSBitmapImageRep, inkLum: Double) -> [Row] {
        let width = min(masked.pixelsWide, bare.pixelsWide)
        let height = min(masked.pixelsHigh, bare.pixelsHigh)
        let rowPixels = CGFloat(height) / CGFloat(backdrops.count)
        return backdrops.indices.map { index in
            var row = Row()
            let top = Int((CGFloat(index) * rowPixels).rounded())
            let bottom = min(height, Int((CGFloat(index + 1) * rowPixels).rounded()))
            for x in 0..<width {
                for y in top..<bottom {
                    guard let mask = masked.colorAt(x: x, y: y), isMaskColor(mask),
                          let background = bare.colorAt(x: x, y: y) else { continue }
                    row.inkPixels += 1
                    row.worst = min(row.worst, NFRContrast.ratio(inkLum, NFRContrast.relativeLuminance(background)))
                }
            }
            return row
        }
    }

    /// The mask and the bare pictures, on screen where the window server can
    /// capture them, else off screen with the reason.
    private func pictures(material: HeaderBar.Material, appearance: NSAppearance.Name)
        -> (masked: NSBitmapImageRep, bare: NSBitmapImageRep, onScreen: String?) {
        // The glyph mask comes from a picture with an unmistakable ink (so the
        // mask exists even when the real symbol would vanish into the frame);
        // the contrast is then measured with the symbol colour that ships.
        var maskMaterial = material
        maskMaterial.symbol = .magenta
        let reason: String
        switch (NFROnScreen.capture(stack(material: maskMaterial, symbols: true), size: stackSize,
                                    appearance: appearance),
                NFROnScreen.capture(stack(material: material, symbols: false), size: stackSize,
                                    appearance: appearance)) {
        case let (.picture(masked), .picture(bare)):
            let rows = measure(masked: masked, bare: bare, inkLum: 0)
            if rows.allSatisfy({ $0.inkPixels > 40 }) { return (masked, bare, nil) }
            reason = "the capture shows no symbols (ink pixels \(rows.map(\.inkPixels)))"
        case let (.unavailable(why), _), let (_, .unavailable(why)):
            reason = why
        }
        let masked = NFROffscreen.render(stack(material: maskMaterial, symbols: true), size: stackSize,
                                         appearance: appearance)
        let bare = NFROffscreen.render(stack(material: material, symbols: false), size: stackSize,
                                       appearance: appearance)
        return (masked, bare, reason)
    }

    /// WIN-22 / MIRROR-22. Each material in the appearance that carries it
    /// (`HeaderBar.material(for:)`, as the chrome picks it): the dark capsule
    /// is only ever drawn in a dark appearance.
    func testSymbolsKeepThreeToOneOverWhiteBlackAndBusyFrames() {
        let required = NFRTestLimits.shared.double("contrast_min")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let material = HeaderBar.material(for: NSAppearance(named: appearance))
            let name = appearance == .darkAqua ? "dark" : "light"
            let (masked, bare, offScreenReason) = pictures(material: material, appearance: appearance)
            let surface = offScreenReason == nil ? "on screen" : "off screen"
            if let offScreenReason {
                let line = "BarContrastTests [WIN-22]: \(name): on-screen capture unavailable (\(offScreenReason)); "
                    + "measured the off-screen render, which cannot see the glass or Reduce Transparency"
                print(line) // log-ok: an appearance, a capture reason and counts only
            }
            let rows = measure(masked: masked, bare: bare, inkLum: NFRContrast.relativeLuminance(material.symbol))
            for (kind, row) in zip(backdrops, rows) {
                let line = "BarContrastTests [WIN-22]: \(name) over \(kind), \(surface): worst "
                    + String(format: "%.2f", row.worst) + ":1 over \(row.inkPixels) ink pixels, reduceTransparency "
                    + "\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)"
                print(line) // log-ok: an appearance, a backdrop, a ratio, a count and a setting only
                XCTAssertGreaterThan(row.inkPixels, 40, "\(name) over \(kind), \(surface): the picture drew no symbols")
                XCTAssertGreaterThanOrEqual(row.worst, required,
                    "\(name) appearance over \(kind), \(surface): worst symbol contrast \(row.worst):1, wanted \(required):1")
            }
        }
    }
}

/// The bar's material comes from the window's appearance as soon as the chrome
/// is in a window, not only on a later change: a window created in Dark kept a
/// light bar until something changed the system appearance (a capture showed it).
@MainActor
final class BarAppearanceTests: XCTestCase {
    private func chrome(in appearance: NSAppearance?) -> (NSWindow, StreamChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let chrome = StreamChromeView(video: VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780)),
                                      style: .compact)
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
