// The Framed bar's centred name (WIN-68): the app's name, or the phone's in
// the Phone Mirror, on the bar's line. Everything here is pure: the view
// (WindowChrome's FramedChromeView) reads the same layout the tests pin.

import AppKit

/// The title's numbers and its pure layout. The title is one line, centred
/// on the bar's line, 8 pt clear of the lights and the right-hand row.
enum BarTitle {
    static let pointSize: CGFloat = 13
    static let weight: NSFont.Weight = .semibold
    /// Clearance from the traffic lights and the right-hand controls.
    static let sideGap: CGFloat = 8
    /// Narrower than this and the title hides instead of shrinking further.
    static let minimumWidth: CGFloat = 40
    /// A name that does not fit whole needs at least this much room to be
    /// worth truncating: below it the middle ellipsis leaves two or three
    /// letters, which reads worse than no title.
    static let minimumTruncatedWidth: CGFloat = 96

    static func font() -> NSFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }

    /// The one title field's construction, whatever the style: 13 pt semibold,
    /// one centred line, never editable, and the accessibility value comes from
    /// the window, not a label. The style owns only the colour and its frame.
    static func configure(_ field: NSTextField) {
        field.font = font()
        field.alignment = .center
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.setAccessibilityElement(false)
    }

    /// Puts `text` in a title field at `frame`: whole when it fits (clipping),
    /// middle-truncated only below the text's width, hidden with no frame.
    static func layOut(_ text: String?, in field: NSTextField, frame: NSRect?) {
        field.stringValue = text ?? ""
        guard let frame else {
            field.isHidden = true
            field.frame = .zero
            return
        }
        field.isHidden = false
        field.frame = frame
        field.lineBreakMode = lineBreakMode(text: text, width: frame.width)
    }

    /// The width a title field needs to draw `text` whole on one line: the
    /// cell's own measure, its edge padding included, rounded up. The glyphs'
    /// width plus a guess at the padding fell short by about 2 pt and clipped
    /// the last glyph of a name that "fit" ("Settings (FakePhone" — #45).
    static func textWidth(_ text: String) -> CGFloat {
        MainActor.assumeIsolated {
            let field = measuringField
            field.stringValue = text
            return ceil(field.cell?.cellSize.width ?? 0)
        }
    }

    /// A title field built like the drawn ones (`configure`, clipping), kept
    /// for measuring: its cell is the one whose edges decide the fit.
    @MainActor private static let measuringField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        configure(field)
        field.lineBreakMode = .byClipping
        return field
    }()

    /// The field's line-break mode for a name in `width`. An `NSTextField`
    /// reserves the middle ellipsis's width even when the whole line fits, so
    /// a field exactly as wide as its name would always truncate: only ask
    /// for middle truncation when the frame is narrower than the line, and
    /// clip (which draws the whole line) otherwise.
    static func lineBreakMode(text: String?, width: CGFloat) -> NSLineBreakMode {
        guard let text else { return .byTruncatingMiddle }
        return width < textWidth(text) ? .byTruncatingMiddle : .byClipping
    }

    /// The title's frame in the chrome's coordinates (origin bottom-left),
    /// nil when it is too narrow or has no text. `lightsEnd` is the right
    /// edge of the zoom light's slot; `rightRowStart` is the first pixel of
    /// the kind's action capsules (or of the Live Text capsule when there are
    /// none), so the title yields its width to both.
    static func frame(text: String?, windowWidth: CGFloat, barHeight: CGFloat,
                      boundsHeight: CGFloat, lightsEnd: CGFloat,
                      rightRowStart: CGFloat) -> NSRect? {
        guard let text, !text.isEmpty, barHeight > 0, windowWidth > 0 else { return nil }
        guard let available = availableWidth(windowWidth: windowWidth, barHeight: barHeight,
                                             lightsEnd: lightsEnd, rightRowStart: rightRowStart),
              available >= minimumWidth else { return nil }
        if textWidth(text) > available, available < minimumTruncatedWidth { return nil }
        let width = min(textWidth(text), available)
        let height = ceil(font().ascender - font().descender + font().leading)
        // Centred on the bar's own line (the window's centre) while the room
        // allows it; clamped into the space the controls leave otherwise.
        let x = min(max(windowWidth / 2 - width / 2, lightsEnd + sideGap),
                    rightRowStart - sideGap - width)
        return NSRect(x: x, y: boundsHeight - barHeight + (barHeight - height) / 2,
                      width: width, height: height)
    }

    /// The text to draw and its frame, with the phone suffix dropped before the
    /// app's name is truncated: "<App> (<phone>)" whole when it fits, else
    /// "<App>" under the existing whole-name thresholds (96 pt to truncate,
    /// 40 pt to show at all). `base` is the name without the suffix.
    static func fitting(text: String?, base: String?, windowWidth: CGFloat, barHeight: CGFloat,
                        boundsHeight: CGFloat, lightsEnd: CGFloat,
                        rightRowStart: CGFloat) -> (text: String, frame: NSRect)? {
        guard let text, !text.isEmpty else { return nil }
        guard let available = availableWidth(windowWidth: windowWidth, barHeight: barHeight,
                                             lightsEnd: lightsEnd, rightRowStart: rightRowStart),
              available >= minimumWidth else { return nil }
        let chosen: String
        if textWidth(text) <= available {
            chosen = text
        } else if let base, !base.isEmpty, base != text {
            // The suffix goes first, never the app's own name.
            chosen = base
        } else {
            chosen = text
        }
        guard let frame = frame(text: chosen, windowWidth: windowWidth, barHeight: barHeight,
                                boundsHeight: boundsHeight, lightsEnd: lightsEnd,
                                rightRowStart: rightRowStart) else { return nil }
        return (chosen, frame)
    }

    /// The width the title may use between the lights and the right-hand row,
    /// nil when the bar has no room.
    static func availableWidth(windowWidth: CGFloat, barHeight: CGFloat,
                               lightsEnd: CGFloat, rightRowStart: CGFloat) -> CGFloat? {
        guard barHeight > 0, windowWidth > 0 else { return nil }
        let left = lightsEnd + sideGap
        let right = rightRowStart - sideGap
        guard right > left else { return nil }
        return right - left
    }
}

/// What each window kind puts in its bar (WIN-68, MIRROR-26). Only names,
/// never a host, URL, task label or placeholder.
enum BarTitleName {
    /// An app window: the app's own label alone, trimmed.
    static func app(_ label: String?) -> String? {
        trimmed(label)
    }

    /// The bar's whole name for an app: "<App> (<phone>)" while the phone's
    /// display name is known and is not already the base; a phone name alone
    /// stays alone (the Mirror).
    static func withPhone(_ base: String?, phone: String?) -> String? {
        guard let base = trimmed(base) else { return nil }
        guard let phone = trimmed(phone), phone != base else { return base }
        return "\(base) (\(phone))"
    }

    /// The Phone Mirror: the phone's display name (the nickname first).
    static func phone(displayName: String, fallback: String?) -> String? {
        if let display = trimmed(displayName) { return display }
        return trimmed(fallback)
    }

    /// A link or a handoff window: its app's name once the phone has reported
    /// the package; nothing before that (a host or URL never rides the bar).
    static func adoptedApp(_ label: String?) -> String? {
        trimmed(label)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
