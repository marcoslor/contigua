// The framed bar's system blur (WIN-40). NSBackgroundExtensionView draws the
// bar as a mirror under a CABackdropLayer whose private `variableBlur` filter
// (a gradient mask, radius 5) makes it progressive. The bar turns that radius
// up to `BarBlur.radius` by copying the filter, setting the radius and
// reassigning `filters`; the mask and every other property stay as the system
// made them. A macOS whose backdrop has no such filter keeps its own radius.

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

/// Re-applies the bar's system blur whenever an observed event can bring a
/// rebuilt backdrop (WIN-40). The extension view builds its backdrop lazily,
/// once the stream it mirrors has a size, and macOS may rebuild it; nothing
/// here runs on a timer or per frame. Missing is a fact, said once per window.
final class BarBlurTuner {
    typealias Lookup = (CALayer) -> CGFloat?

    private let lookup: Lookup
    private let logFailure: () -> Void
    private var loggedMissing = false

    init(lookup: @escaping Lookup = { BarBlur.tuneSystemBlur(in: $0) },
         logFailure: @escaping () -> Void = {
             Log.video.notice("bar blur: system filter not found")
         }) {
        self.lookup = lookup
        self.logFailure = logFailure
    }

    /// True when the system's filter was found and now carries the radius.
    /// `reportMissing` waits for a checkpoint where the hosting view has had
    /// its chance to build the backdrop (the first frame): a layout before
    /// that is not evidence that the system has no filter.
    @discardableResult
    func apply(in root: CALayer?, reportMissing: Bool = false) -> Bool {
        guard let root else { return false }
        if lookup(root) != nil { return true }
        if reportMissing && !loggedMissing {
            loggedMissing = true
            logFailure()
        }
        return false
    }
}
