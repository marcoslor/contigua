// tap, long_press, swipe, type_text and press_key (docs/design/mcp.md, MCP-80…94).

import Foundation

extension MCPToolHost {
    // MARK: Input

    func tap(window id: Int, x: Double, y: Double) throws -> [String: Any] {
        let window = try requireInputWindow(id)
        send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
        send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
        return ["ok": true, "window": id]
    }

    /// WIN-79: the element a ref named in the tree last read for this window.
    /// The ref is resolved here, and the TOUCH carries the same 0..1 point a
    /// coordinate tap would; a ref from an older tree is refused, never used.
    /// The answer echoes the read the ref came from and the node's box, so a
    /// client can tell which screen it pressed on rather than guess.
    func tap(window id: Int, ref: String) throws -> [String: Any] {
        let window = try requireInputWindow(id)
        let resolution = controller.uiTreeResolved(ref: ref, stream: window.stream)
        switch UITreeTapPlan(resolution, ref: ref) {
        case .press(let point, let snapshot, let box):
            send(.touch(TouchEvent(action: .down, nx: Float(point.x), ny: Float(point.y))), to: window)
            send(.touch(TouchEvent(action: .up, nx: Float(point.x), ny: Float(point.y))), to: window)
            var answer: [String: Any] = ["ok": true, "window": id, "ref": ref,
                                         "snapshot": snapshot,
                                         "x": point.x, "y": point.y]
            if let box { answer["box"] = box }
            return answer
        case .refuse(let sentence):
            // A stale (F1), closed (F4) or off-screen (F9) ref presses nothing:
            // stale_ref or off_screen, with #162's sentence (MCP-6).
            throw MCPToolError.tapRefusal(resolution, ref: ref, window: id)
                ?? MCPToolError.failed(sentence, window: id)
        }
    }

    func longPress(window id: Int, x: Double, y: Double, ms: Int) async throws -> [String: Any] {
        let window = try requireInputWindow(id)
        send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
        try? await Task.sleep(for: .milliseconds(ms))
        send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
        return ["ok": true, "window": id, "ms": ms]
    }

    /// Down, ~60 Hz interpolated moves for `ms`, up. The endpoints are exact;
    /// intermediate steps never overshoot either end.
    func swipe(window id: Int, x1: Double, y1: Double,
                      x2: Double, y2: Double, ms: Int) async throws -> [String: Any] {
        let window = try requireInputWindow(id)
        let steps = max(1, Int((Double(ms) / 1000 * 60).rounded()))
        let interval = ms / steps
        send(.touch(TouchEvent(action: .down, nx: Float(x1), ny: Float(y1))), to: window)
        for step in 1...steps {
            if interval > 0 {
                try? await Task.sleep(for: .milliseconds(interval))
            }
            let t = Double(step) / Double(steps)
            let nx = x1 + (x2 - x1) * t
            let ny = y1 + (y2 - y1) * t
            send(.touch(TouchEvent(action: .move, nx: Float(nx), ny: Float(ny))), to: window)
        }
        send(.touch(TouchEvent(action: .up, nx: Float(x2), ny: Float(y2))), to: window)
        return ["ok": true, "window": id, "ms": ms]
    }

    func typeText(window id: Int, text: String) throws -> [String: Any] {
        let window = try requireInputWindow(id)
        controller.windows.session.text(stream: window.stream, text: text)
        return ["ok": true, "window": id, "characters": text.count]
    }

    func pressKey(window id: Int, key: MCPKey) throws -> [String: Any] {
        let window = try requireInputWindow(id)
        if let action = key.navAction {
            controller.windows.session.nav(stream: window.stream, action: action)
        } else if let keycode = key.keycode {
            controller.windows.session.key(KeyEvent(action: 0, keycode: keycode), stream: window.stream)
            controller.windows.session.key(KeyEvent(action: 1, keycode: keycode), stream: window.stream)
        }
        return ["ok": true, "window": id, "key": key.rawValue]
    }

    func send(_ command: InputMapper.Command, to window: StreamWindowController) {        let session = controller.windows.session
        switch command {
        case .touch(let event): session.touch(event, stream: window.stream)
        case .key(let event): session.key(event, stream: window.stream)
        case .text(let text): session.text(stream: window.stream, text: text)
        case .nav(let action): session.nav(stream: window.stream, action: action)
        default: break
        }
    }
}
