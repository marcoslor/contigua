// The Deck's search field, for the window's own Find key and the e2e.
//
// The field is SwiftUI's `.searchable` field, which macOS puts in the window's
// toolbar (an NSSearchToolbarItem). The Deck's ⌘F focuses it and selects what
// is already typed, as ⌘F does in any Mac window; the e2e reads the same
// AppKit state back (`decksearch`) instead of trusting a debug shortcut.

import AppKit

@MainActor
enum DeckSearch {
    /// The Deck window's search field: the toolbar's, else the first one in
    /// the content (a future placement that is not the toolbar).
    static func field(in window: NSWindow) -> NSSearchField? {
        for item in window.toolbar?.items ?? [] {
            if let search = item as? NSSearchToolbarItem { return search.searchField }
            if let field = item.view as? NSSearchField { return field }
        }
        return find(in: window.contentView)
    }

    /// Focus the field and select all of its text: the ⌘F behaviour.
    static func selectAll(in window: NSWindow) {
        guard let field = field(in: window) else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// The Deck's Find: the window's own search-focus path (SwiftUI's
    /// `searchFocusRequest`), then the field's text selected. The second pass
    /// runs after SwiftUI applies the focus request, so a re-render cannot put
    /// the caret back at the end or take the field's editor away.
    static func focusAndSelect(in window: NSWindow, request: () -> Void) {
        request()
        selectAll(in: window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            selectAll(in: window)
        }
    }

    private static func find(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for child in view.subviews {
            if let found = find(in: child) { return found }
        }
        return nil
    }

    /// Setup for the e2e: put `text` in the field through its editor, as typing
    /// would (the ⌘F press itself is a real key event).
    static func setText(_ text: String, in window: NSWindow) {
        guard let field = field(in: window) else { return }
        window.makeFirstResponder(field)
        field.selectText(nil)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: NSRange(location: 0, length: field.stringValue.count))
        } else {
            field.stringValue = text
        }
    }

    /// The field's state as JSON (the e2e's read): focused, its text, the
    /// selection, and which window is key.
    private struct Report: Encodable {
        var focused: Bool
        var text: String
        var selection: [Int]
        var keyWindow: String
        /// The window's first responder, by class: whether the field editor
        /// really has the keys (currentEditor alone can outlive the focus).
        var firstResponder: String
    }

    static func dump(to path: String) -> Bool {
        guard let window = DeckWindow.window, let field = field(in: window) else { return false }
        let editor = field.currentEditor()
        let key: String
        if let keyWindow = NSApp.keyWindow {
            key = keyWindow === window ? "deck" : "other"
        } else {
            key = "none"
        }
        let report = Report(focused: editor != nil && window.isKeyWindow && window.firstResponder === editor,
                            text: field.stringValue,
                            selection: (editor as? NSTextView).map {
                                [($0).selectedRange.location, ($0).selectedRange.length]
                            } ?? [0, 0],
                            keyWindow: key,
                            firstResponder: window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
