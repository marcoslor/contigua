// Where the Settings window opens and comes back to (docs/specs/settings.md,
// SET-WIN-09). The placement is one pure function over screen frames, so the
// rules — centre on a fresh open, keep a saved origin, rescue one whose screen
// is gone — are unit-tested without a window.

import AppKit

enum SettingsPlacement {
    /// One saved origin per profile: the profile's defaults are the store.
    static let originKey = "settings.windowOrigin"

    /// The origin for a window of `size`: `saved` when it is still on a screen
    /// (pushed back inside that screen when it is only partly off), centred on
    /// `screens[0]` when there is no saved origin or it is on no screen at all.
    /// `screens[0]` is the one to centre on (the key window's, else the main
    /// screen); the others only keep a saved origin valid, so a window on a
    /// second display stays there.
    static func origin(saved: CGPoint?, screens: [CGRect], size: CGSize) -> CGPoint {
        guard let home = screens.first else { return saved ?? .zero }
        guard let saved else { return centre(in: home, size: size) }
        let frame = CGRect(origin: saved, size: size)
        let overlaps = screens.map { screen -> (screen: CGRect, area: CGFloat) in
            let overlap = screen.intersection(frame)
            return (screen, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 else {
            return centre(in: home, size: size)
        }
        return clamped(saved, inside: best.screen, size: size)
    }

    static func centre(in screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: (screen.midX - size.width / 2).rounded(),
                y: (screen.midY - size.height / 2).rounded())
    }

    static func clamped(_ origin: CGPoint, inside screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width)),
                y: min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height)))
    }

    /// The origin stored for this profile, if any. A value the person's defaults
    /// hold that is not a point is no origin: the window opens centred.
    static func saved(in defaults: UserDefaults) -> CGPoint? {
        guard let text = defaults.string(forKey: originKey) else { return nil }
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func save(_ origin: CGPoint, in defaults: UserDefaults) {
        defaults.set("\(origin.x),\(origin.y)", forKey: originKey)
    }
}
