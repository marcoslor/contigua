// The Compact bar's system blur (WIN-40, WIN-67). NSBackgroundExtensionView
// draws the bar as a mirror under a CABackdropLayer whose private
// `variableBlur` filter (a gradient mask, radius 5) makes it progressive. The
// bar turns that radius up to `BarBlur.radius` by copying the filter, setting
// the radius and reassigning `filters`; the mask and every other property stay
// as the system made them. A macOS whose backdrop has no such filter keeps its
// own radius.
//
// When: the extension view builds its backdrop in a layout pass of its own,
// after the chrome's layout (measured on macOS 26: nothing on its first pass,
// the backdrop at 5 pt by its second). Tuning from the chrome's events alone
// missed it whenever the first frame came before that pass — the bar kept a
// near-sharp 5 pt mirror that read as a see-through bar until some later event
// re-laid the chrome out (issue #45). BarMirrorView tunes after each of the
// extension view's own passes instead.

import AppKit

enum BarBlur {
    /// The radius of the bar's progressive blur (the system's own is 5).
    static let radius: CGFloat = 30

    /// The radius the layer tree's `variableBlur` filter carries right now,
    /// nil when the backdrop or its filter is not there.
    static func systemRadius(in root: CALayer?) -> CGFloat? {
        guard let root, let found = backdropFilter(in: root) else { return nil }
        return (found.filter.value(forKey: "inputRadius") as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// Sets the radius on the backdrop's `variableBlur` filter and returns the
    /// radius it carries afterwards, nil when no system filter was found.
    /// The filter is copied because CAFilter is shared with the system.
    @discardableResult
    static func tuneSystemBlur(in root: CALayer?, radius: CGFloat = radius) -> CGFloat? {
        guard let root, let found = backdropFilter(in: root) else { return nil }
        var filters = found.layer.filters as? [NSObject] ?? []
        var changed = false
        filters = filters.map { filter in
            guard (filter.value(forKey: "name") as? String) == "variableBlur" else { return filter }
            guard (filter.value(forKey: "inputRadius") as? NSNumber)?.doubleValue != Double(radius),
                  let copy = filter.copy() as? NSObject else { return filter }
            copy.setValue(radius, forKey: "inputRadius")
            changed = true
            return copy
        }
        if changed { found.layer.filters = filters }
        let tuned = changed ? filters.first { ($0.value(forKey: "name") as? String) == "variableBlur" } : found.filter
        return (tuned?.value(forKey: "inputRadius") as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// What the layer tree holds when the filter is missing, for the one fact
    /// line: how many backdrops and every filter name, no addresses or data.
    static func diagnosis(in root: CALayer) -> String {
        var backdrops = 0
        var portals = 0
        var filters: [String] = []
        func walk(_ layer: CALayer) {
            let className = String(describing: type(of: layer))
            if className.contains("Backdrop") { backdrops += 1 }
            if className.contains("Portal") { portals += 1 }
            for filter in (layer.filters as? [NSObject]) ?? [] {
                let name = (filter.value(forKey: "name") as? String) ?? String(describing: type(of: filter))
                if !filters.contains(name) { filters.append(name) }
            }
            for sub in layer.sublayers ?? [] { walk(sub) }
        }
        walk(root)
        return "backdrops=\(backdrops) portals=\(portals) filters=[\(filters.joined(separator: ","))]"
    }

    /// The backdrop and the one filter that draws the bar's blur.
    private static func backdropFilter(in root: CALayer) -> (layer: CALayer, filter: NSObject)? {
        if String(describing: type(of: root)) == "CABackdropLayer",
           let filters = root.filters as? [NSObject] {
            for filter in filters where (filter.value(forKey: "name") as? String) == "variableBlur" {
                return (root, filter)
            }
        }
        for sub in root.sublayers ?? [] {
            if let found = backdropFilter(in: sub) { return found }
        }
        return nil
    }
}

/// The Compact bar's mirror: the system's extension view, saying when it has
/// run a pass of its own. Its layout and its layer update are where it builds
/// (and may rebuild) the backdrop, so `onSystemPass` runs right after each:
/// the radius is set the moment the backdrop exists, not at the next event
/// that happens to re-layout the chrome. Observation only; no timer, nothing
/// per frame.
final class BarMirrorView: NSBackgroundExtensionView {
    var onSystemPass: (() -> Void)?

    override func layout() {
        super.layout()
        onSystemPass?()
    }

    override func updateLayer() {
        super.updateLayer()
        onSystemPass?()
    }
}

/// Re-applies the bar's system blur whenever the extension view has run a
/// pass of its own or an observed event can bring a rebuilt backdrop (WIN-40).
/// A backdrop that is not there yet is not evidence of a missing filter: the
/// system builds it late. The fact is said once, when a window that wore the
/// Compact bar closes without its filter ever having been found, with what the
/// layer tree held instead.
final class BarBlurTuner {
    typealias Lookup = (CALayer) -> CGFloat?
    typealias Diagnosis = (CALayer) -> String

    private let lookup: Lookup
    private let diagnosis: Diagnosis
    private let logFailure: (String) -> Void
    /// Compact asked for the radius at least once, and whether it was found.
    private(set) var tried = false
    private(set) var found = false

    init(lookup: @escaping Lookup = { BarBlur.tuneSystemBlur(in: $0) },
         diagnosis: @escaping Diagnosis = { BarBlur.diagnosis(in: $0) },
         logFailure: @escaping (String) -> Void = { detail in
             Log.video.notice("bar blur: system filter never found in this window (\(detail, privacy: .public))")  // log-ok: layer class counts and private filter names
         }) {
        self.lookup = lookup
        self.diagnosis = diagnosis
        self.logFailure = logFailure
    }

    /// True when the system's filter was found and now carries the radius.
    @discardableResult
    func apply(in root: CALayer?) -> Bool {
        guard let root else { return false }
        tried = true
        guard lookup(root) != nil else { return false }
        found = true
        return true
    }

    /// The window is closing: one fact if the bar was live and the filter
    /// never turned up, nothing otherwise.
    func windowClosing(root: CALayer?) {
        guard tried, !found else { return }
        logFailure(root.map(diagnosis) ?? "no layer")
    }
}
