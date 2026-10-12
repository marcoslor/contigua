// NSEvent -> protocol message mapping. Nothing is coalesced except ASCII text,
// which is batched for up to 8 ms so a fast typist produces one `text` frame
// instead of one per character. Touch/scroll/keys are sent immediately.

import AppKit

final class InputMapper {
    enum Command {
        case touch(TouchAction, Float, Float)
        case scroll(ScrollEvent)
        case key(KeyEvent)
        case text(String)
        case nav(String)
        case adjustDensity(Double)
        case resetDensity
    }

    static let textBatchInterval: TimeInterval = 0.008

    /// Android KEYCODE_* for the non-printable keys we forward.
    static let keyMap: [UInt16: UInt32] = [
        36: 66,   // Return
        51: 67,   // Delete (backspace)
        117: 112, // Forward delete
        48: 61,   // Tab
        123: 21,  // Left
        124: 22,  // Right
        125: 20,  // Down
        126: 19,  // Up
        115: 122, // Home
        119: 123, // End
        116: 92,  // Page Up
        121: 93,  // Page Down
    ]

    /// Command-key combos forwarded as KEY with meta 0x3000.
    static let metaKeyMap: [UInt16: UInt32] = [
        0: 29, // A
        8: 31, // C
        7: 52, // X
        6: 54, // Z
    ]

    static let metaStateCommand: UInt32 = 0x3000 // META_CTRL_ON | META_CTRL_LEFT_ON

    let stream: UInt32
    var send: ((Command) -> Void)?
    var videoRectProvider: () -> CGRect = { .zero }
    var locationProvider: (NSEvent) -> CGPoint = { _ in .zero }
    var viewIsFlipped: () -> Bool = { false }
    /// Phone-mode windows add ⇧⌘H (home) and ⌘↑ (recents).
    var isPhoneMode = false
    /// Esc reaches the phone only from the focused window with no sheet open.
    var escapeAllowed: () -> Bool = { true }

    static let keyCodeEscape: UInt16 = 53
    static let keyCodeH: UInt16 = 4
    static let keyCodeUpArrow: UInt16 = 126

    private var pendingText = ""
    private var textFlush: DispatchWorkItem?

    init(stream: UInt32) { self.stream = stream }

    // MARK: Geometry

    func normalized(_ point: CGPoint) -> (nx: Float, ny: Float) {
        Letterbox.normalized(point: point, videoRect: videoRectProvider(), flipped: viewIsFlipped())
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        flushText()
        let (nx, ny) = normalized(locationProvider(event))
        LatencyLog.shared.noteTouchDown(stream: stream)
        send?(.touch(.down, nx, ny))
    }

    func mouseDragged(_ event: NSEvent) {
        let (nx, ny) = normalized(locationProvider(event))
        send?(.touch(.move, nx, ny))
    }

    func mouseUp(_ event: NSEvent) {
        let (nx, ny) = normalized(locationProvider(event))
        send?(.touch(.up, nx, ny))
    }

    func rightMouseDown(_ event: NSEvent) {
        flushText()
        send?(.nav("back"))
    }

    /// Middle button -> home, extra buttons 3/4 (the usual side buttons) -> back.
    func otherMouseDown(_ event: NSEvent) {
        flushText()
        switch event.buttonNumber {
        case 2: send?(.nav("home"))
        case 3, 4: send?(.nav("back"))
        default: break
        }
    }

    /// Two-finger swipe from the window's left edge (see EdgeSwipeClassifier).
    func edgeSwipeBack() {
        flushText()
        send?(.nav("back"))
    }

    func scrollWheel(_ event: NSEvent) {
        flushText()
        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            dx /= 20.0
            dy /= 20.0
        } else {
            dx = dx == 0 ? 0 : (dx > 0 ? 1 : -1)
            dy = dy == 0 ? 0 : (dy > 0 ? 1 : -1)
        }
        guard dx != 0 || dy != 0 else { return }
        let (nx, ny) = normalized(locationProvider(event))
        send?(.scroll(ScrollEvent(nx: nx, ny: ny, hscroll: Float(dx), vscroll: Float(dy))))
    }

    // MARK: Keyboard

    func keyDown(_ event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) {
            // Phone mode: ⇧⌘H = home, ⌘↑ = recents. ⇧⌘H is not ⌘H: no clash
            // with the app menu's Hide.
            if flags.contains(.shift), event.keyCode == Self.keyCodeH {
                if isPhoneMode {
                    flushText()
                    send?(.nav("home"))
                }
                return
            }
            if event.keyCode == Self.keyCodeUpArrow {
                if isPhoneMode {
                    flushText()
                    send?(.nav("recents"))
                }
                return
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "[":
                flushText()
                send?(.nav("back"))
            case "v":
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    flushText()
                    send?(.text(text))
                }
            case "a", "c", "x", "z":
                if let code = Self.metaKeyMap[event.keyCode] {
                    flushText()
                    send?(.key(KeyEvent(action: 0, keycode: code, metaState: Self.metaStateCommand)))
                }
            case "+", "=":
                flushText()
                send?(.adjustDensity(0.25))
            case "-":
                flushText()
                send?(.adjustDensity(-0.25))
            case "0":
                flushText()
                send?(.resetDensity)
            default:
                break
            }
            return
        }
        if event.keyCode == Self.keyCodeEscape { // Esc
            guard escapeAllowed() else { return }
            flushText()
            send?(.nav("back"))
            return
        }
        if let code = Self.keyMap[event.keyCode] {
            flushText()
            send?(.key(KeyEvent(action: 0, keycode: code)))
            return
        }
        guard !flags.contains(.control), let chars = event.characters, !chars.isEmpty else { return }
        let printable = chars.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
        if printable { appendText(chars) }
    }

    func keyUp(_ event: NSEvent) {
        if let code = Self.keyMap[event.keyCode] {
            send?(.key(KeyEvent(action: 1, keycode: code)))
        } else if event.modifierFlags.contains(.command), let code = Self.metaKeyMap[event.keyCode] {
            send?(.key(KeyEvent(action: 1, keycode: code, metaState: Self.metaStateCommand)))
        }
    }

    // MARK: Text batching

    func flushText() {
        textFlush?.cancel()
        textFlush = nil
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText = ""
        send?(.text(text))
    }

    private func appendText(_ text: String) {
        pendingText += text
        guard textFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushText() }
        textFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.textBatchInterval, execute: work)
    }
}
