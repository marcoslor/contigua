// Where the Deck opens and comes back to (docs/specs/deck.md, DECK-19 and
// CONV-MAC-12). The placement is one pure function over screen frames, the same
// pattern as SettingsPlacement (SET-WIN-09), so the rules — a stored frame comes
// back, a frame on no screen is centred, a frame larger than the screen is
// shrunk — are unit-tested without a window.

import AppKit

enum DeckPlacement {
    /// The frame with no stored one: DECK-19's 760×600, centred by AppKit.
    static let defaultSize = CGSize(width: 760, height: 600)
    /// One saved frame per profile: the profile's defaults are the store.
    static let frameKey = "deck.windowFrame"

    /// The frame to open at. `saved` is the frame last stored for this profile,
    /// `screens` the visible frames (the home screen first) and `minimum` the
    /// Deck's own minimum size.
    ///
    /// - A stored frame that fits a current screen comes back exactly.
    /// - Otherwise the Deck opens centred on the home screen, at the stored size
    ///   when it still fits there (a person's size survives an unplugged
    ///   display), else at the default size.
    /// - The result is never smaller than `minimum` and never larger than the
    ///   screen it opens on.
    static func frame(saved: CGRect?, screens: [CGRect], minimum: CGSize) -> CGRect {
        guard let home = screens.first else {
            return saved ?? CGRect(origin: .zero, size: defaultSize)
        }
        let fallbackSize = fitted(defaultSize, minimum: minimum, screen: home)
        guard let saved else { return centred(fallbackSize, in: home) }
        // The screen it fits, else None: a frame on the home screen wins over
        // one that merely overlaps it.
        if let host = screens.first(where: { $0.contains(saved) }) {
            return CGRect(origin: saved.origin, size: fitted(saved.size, minimum: minimum, screen: host))
        }
        let size = fitted(saved.size, minimum: minimum, screen: home)
        return centred(size, in: home)
    }

    static func centred(_ size: CGSize, in screen: CGRect) -> CGRect {
        CGRect(x: (screen.midX - size.width / 2).rounded(),
               y: (screen.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }

    /// `size` inside `minimum` and the screen's own size: a Deck larger than
    /// the screen is cropped controls, and smaller than its minimum is a broken
    /// layout.
    static func fitted(_ size: CGSize, minimum: CGSize, screen: CGRect) -> CGSize {
        let width = min(max(size.width, minimum.width), screen.width)
        let height = min(max(size.height, minimum.height), screen.height)
        return CGSize(width: width, height: height)
    }

    /// The frame stored for this profile, if any. A value that is not four
    /// numbers is no frame: the Deck opens at its default.
    static func saved(in defaults: UserDefaults) -> CGRect? {
        guard let text = defaults.string(forKey: frameKey) else { return nil }
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1],
              let width = parts[2], let height = parts[3],
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func save(_ frame: CGRect, in defaults: UserDefaults) {
        let text = "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),"
            + "\(Int(frame.width.rounded())),\(Int(frame.height.rounded()))"
        defaults.set(text, forKey: frameKey)
    }

    /// A rect for a log line: whole points, never a person's data.
    static func summary(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))-"
            + "\(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
