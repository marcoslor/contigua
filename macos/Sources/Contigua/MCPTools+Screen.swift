// screenshot and input_probe (docs/design/mcp.md, MCP-60…64, MCP-99).
//
// A screenshot is the phone's next keyframe for the window, decoded once by
// the window's snapshot decoder and stamped with its seq (MCP-60); the answer
// says how fresh it is and what state the window is in.

import AVFoundation
import CoreVideo
import Foundation

extension MCPToolHost {
    // MARK: Screenshot

    /// MCP-60…63: a frame from after the call, never the display layer's last
    /// buffer (the layer stops presenting behind other windows, #165).
    func screenshot(_ id: Int, ref: String?, wait: MCPWait) async throws -> MCPToolResult {
        guard wait == .settle else { return try await screenshot(id, ref: ref) }
        _ = try requireWindow(id)
        // MCP-61: an offline phone fails at once, settling nothing.
        guard controller.link.isOnline else { throw MCPToolError.phoneOffline(phoneName) }
        // MCP-64: settle first, then the frame from after the call; the
        // answer carries the settle beside it.
        let settle = await settleOnly(id)
        switch try await screenshot(id, ref: ref) {
        case .image(let png, var answer):
            answer["settle"] = MCPActEnvelope.settle(settle)
            return .image(png, answer)
        case let other:
            return other
        }
    }

    func screenshot(_ id: Int, ref: String?) async throws -> MCPToolResult {
        let window = try requireWindow(id)
        // MCP-61: an offline phone fails before its ref is judged.
        guard controller.link.isOnline else { throw MCPToolError.phoneOffline(phoneName) }
        // MCP-50/62/63: the display's pixels, the space of the tree's boxes.
        let size = pixelSize(of: window)
        let crop = try ref.map {
            try ScreenshotCrop.box(for: controller.uiTreeResolved(ref: $0, stream: window.stream),
                                   ref: $0, window: id, size: size)
        }
        // MCP-21: the state is read when the answer (or the failure) is made:
        // a window's first frame can end its opening while the call waits.
        return try await Screenshot.result(id: id, state: { self.stateToken(for: window) },
                                           source: window, size: size, crop: crop,
                                           online: controller.link.isOnline, phone: phoneName)
    }

    /// P0 (pmaxx): the tap goes through the same session path a click does;
    /// the probe's private decoder watches the stream's frames and reports the
    /// first one that changed. `changed_ms` is from the send to that frame's
    /// decode; the display layer shows it on the next refresh (≤ 16.7 ms at
    /// 60 Hz), so the tool's number is the input-to-picture part of
    /// input-to-photon.
    func inputProbe(window id: Int, x: Double, y: Double,
                            width: Double?, height: Double?) async throws -> [String: Any] {
        // MCP-84: the probe's tap holds the window's turn like an input call.
        let client = self.client
        let acts = controller.windowActs
        guard let body = try await acts.exclusive(window: UInt32(id), client: client, {
            try await probe(window: id, x: x, y: y, width: width, height: height)
        }) else { throw MCPToolError.failed("The connection closed.", window: id) }
        return body
    }

    private func probe(window id: Int, x: Double, y: Double,
                       width: Double?, height: Double?) async throws -> [String: Any] {
        let window = try requireInputWindow(id)
        let region: ProbeRegion = {
            if let width, let height {
                return ProbeRegion.around(x: x, y: y, width: width, height: height)
            }
            return .whole
        }()
        let armed = await window.videoView.beginInputProbe(region: region)
        guard armed else {
            await window.videoView.endInputProbe()
            var body: [String: Any] = ["ok": true, "window": id, "frames": 0]
            body["sent_ms"] = NSNull()
            body["changed_ms"] = NSNull()
            return body
        }
        let sent = ProcessInfo.processInfo.systemUptime * 1000
        send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
        send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
        window.videoView.inputProbeTapSent(atMs: sent)
        let outcome = await window.videoView.awaitInputProbe(timeout: 2.0)
        await window.videoView.endInputProbe()
        var body: [String: Any] = ["ok": true, "window": id, "frames": outcome.frames]
        body["sent_ms"] = sent
        body["changed_ms"] = outcome.changedMs.map { $0 as Any } ?? NSNull()
        return body
    }

}

// MARK: - The screenshot source (MCP-60)

/// A decoded frame: the buffer, its count on the window's clock (MCP-20) and
/// when it arrived (uptime). Its age is taken when the answer is made.
struct SnapshotFrame: Equatable {
    /// Where the frame came from.
    enum Origin: Equatable {
        /// MCP-60's normal route: a keyframe counted after the call.
        case keyframe
        /// MCP-60's still route: the frame on the display, answered because the
        /// phone said the window is still since it.
        case displayed
    }
    let buffer: CVPixelBuffer
    let seq: Int
    let at: TimeInterval
    var origin: Origin = .keyframe

    /// Same frame means same count at the same instant from the same route:
    /// the pixel buffer is not comparable.
    static func == (left: Self, right: Self) -> Bool {
        left.seq == right.seq && left.at == right.at && left.origin == right.origin
    }
}

/// What an `window.keyframe` request began: its decode is cancelled by this.
typealias SnapshotTicket = SnapshotSlot.Token

/// What a screenshot reads its frame from: a window, or a fake in the tests.
/// `copyDisplayedFrame` is here so a fake can prove it is read only where the
/// phone itself said the window is still.
@MainActor
protocol ScreenshotSource: AnyObject {
    /// The newest counted frame when the call starts (MCP-20).
    var newestSeq: Int { get }
    /// When that frame arrived; nil before the first.
    var newestAt: TimeInterval? { get }
    /// Live Text's freeze holds the one snapshot decoder.
    var isCapturing: Bool { get }
    /// The last `window.still` (PHONE-21) seen after the newest frame: the
    /// phone itself says nothing has changed since then.
    var stillSince: TimeInterval? { get }
    /// The display layer's buffer: never a screenshot's answer unless the phone
    /// reported the window still (MCP-60).
    func copyDisplayedFrame() -> CVPixelBuffer?
    /// Asks the phone for a keyframe and decodes the first one counted later
    /// than `seq`; `handler` runs once, with the frame or nil. `until` is the
    /// time the call has left: the decode never outlives it (MCP-61).
    func beginSnapshot(after seq: Int, until: TimeInterval,
                       handler: @escaping (SnapshotFrame?) -> Void) -> SnapshotTicket
    /// Asks again while that decode still waits: the phone answers a request
    /// made within 250 ms of an IDR it sent with that IDR and sends nothing
    /// (PATH-41), so one ask can be answered by silence.
    func askKeyframeAgain()
    /// Drops the decode `ticket` began, only if it is still the current one.
    func cancelSnapshot(_ ticket: SnapshotTicket)
    /// Hands the call back to the run loop for one poll of its bound.
    func poll(_ seconds: TimeInterval) async
}

extension StreamWindowController: ScreenshotSource {
    var newestSeq: Int { frameClock.newest }

    var newestAt: TimeInterval? { frameClock.lastFrame }

    var isCapturing: Bool { liveText.state == .capturing }

    var stillSince: TimeInterval? { stillAfterFrame }

    func copyDisplayedFrame() -> CVPixelBuffer? { videoView.copyDisplayedFrame() }

    /// MCP-60: the snapshot decoder's frame, stamped with its count.
    func beginSnapshot(after seq: Int, until: TimeInterval,
                       handler: @escaping (SnapshotFrame?) -> Void) -> SnapshotTicket {
        let view = videoView
        let ticket = view.beginFrameSnapshot(after: seq) { buffer, stamp in
            MainActor.assumeIsolated {
                guard let buffer, let stamp else { handler(nil); return }
                handler(SnapshotFrame(buffer: buffer, seq: stamp.seq, at: stamp.at))
            }
        }
        // MCP-61: the decode is dropped with the call's bound, whatever the
        // caller does; a screenshot must not leave a decoder behind.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, until) + 0.05))
            view.cancelFrameSnapshot(ticket)
        }
        return ticket
    }

    func askKeyframeAgain() { videoView.requestKeyframeNow() }

    func cancelSnapshot(_ ticket: SnapshotTicket) { videoView.cancelFrameSnapshot(ticket) }

    func poll(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - The answer (MCP-60…63)

@MainActor
enum Screenshot {
    /// The bound for a keyframe to arrive (MCP-61).
    static let timeout = ScreenshotWait.bound

    /// The `.image` answer for the first keyframe after the call, or
    /// `no_frame`. `state` is read when the answer or failure is made, not at
    /// the call: an opening window may have gone live, a live one stalled or
    /// closed.
    static func result(id: Int, state: () -> String, source: ScreenshotSource,
                       size: (Int, Int), crop: [Int]?,
                       online: Bool = true, phone: String? = nil,
                       encode: @escaping @Sendable (CVPixelBuffer, [Int]?) -> Data? = { FrameGrab.png(from: $0, crop: $1) })
        async throws -> MCPToolResult {
        // MCP-61: an offline window can make no picture; say so before asking.
        guard online else { throw MCPToolError.phoneOffline(phone) }
        let frame = try await waitForFrame(id: id, state: state, source: source)
        let buffer = frame.buffer
        let frameSize = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        // MCP-63: the crop is in display pixels; the frame may be smaller.
        let frameCrop = crop.map { ScreenshotCrop.frameRect(crop: $0, size: size, frame: frameSize) }
        let encoded = await Task.detached(priority: .userInitiated) { () -> (Data?, Bool) in
            (encode(buffer, frameCrop), ScreenshotBlank.isBlank(buffer))
        }.value
        guard let png = encoded.0 else {
            // A picture arrived; it is the encode that failed (MCP-61).
            throw MCPToolError.failed("Window \(id)'s picture arrived but could not be made into a PNG. Try again.",
                                      window: id)
        }
        let image = FrameGrab.scaledSize(sourceWidth: frameSize.0, sourceHeight: frameSize.1, crop: frameCrop)
        // MCP-20: the age now, when the answer is made, not at decode.
        var frameObject = FrameClock.object(
            seq: frame.seq,
            ageMs: FrameClock.ms(since: frame.at, now: ProcessInfo.processInfo.systemUptime))
        // MCP-60: a frame the phone said is still the picture is marked so; a
        // keyframe from after the call is a live frame and carries no flag. The
        // flag sits in `frame` because it explains that frame's own age.
        if frame.origin == .displayed { frameObject["still"] = true }
        var answer: [String: Any] = [
            "window": id,
            "state": state(),
            "frame": frameObject,
            "image": [image.0, image.1],
            "size": [size.0, size.1],
        ]
        if encoded.1 { answer["blank"] = true }
        if let crop { answer["crop"] = crop }
        return .image(png, answer)
    }

    /// The frame the call answers, or `no_frame`/`no_window` at its bound
    /// (MCP-60, MCP-61): the one state machine, driven against the window.
    private static func waitForFrame(id: Int, state: () -> String,
                                      source: ScreenshotSource) async throws -> SnapshotFrame {
        // MCP-61: the bound runs from the call, and covers Live Text's hold.
        var wait = ScreenshotWait.model(callStart: ProcessInfo.processInfo.systemUptime,
                                        hasFrame: source.newestAt != nil)
        // Live Text's freeze holds the one snapshot decoder: wait for it to let
        // go rather than take it away, inside the same bound (MCP-61).
        while source.isCapturing, ProcessInfo.processInfo.systemUptime < wait.deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !source.isCapturing else { throw boundFailure(id: id, state: state) }

        // MCP-60: ask, and decode the first keyframe counted after the call.
        // PATH-41: the repeat is counted from this ask, not from the call, so a
        // Live Text hold longer than it cannot leave the repeat already due.
        let startSeq = source.newestSeq
        var answered: SnapshotFrame?
        let ticket = source.beginSnapshot(
            after: startSeq,
            until: max(0, wait.deadline - ProcessInfo.processInfo.systemUptime)) { frame in
            MainActor.assumeIsolated {
                if answered == nil { answered = frame }
            }
        }
        defer { source.cancelSnapshot(ticket) }
        let askedAt = ProcessInfo.processInfo.systemUptime
        wait = ScreenshotWait.transition(wait, .asked(now: askedAt)).model

        // The wait proper: a frame wins, a still sent since the ask with a shown
        // picture answers, and one more ask covers the phone's duplicate-IDR
        // gate (PATH-41).
        while true {
            let tick = ProcessInfo.processInfo.systemUptime
            let transition = ScreenshotWait.transition(
                wait,
                .tick(now: tick, frame: answered,
                      stillAt: source.stillSince,
                      displayed: displayedFrame(source, askedAt: askedAt)))
            wait = transition.model
            for action in transition.actions {
                switch action {
                case .askAgain:
                    source.askKeyframeAgain()
                case .wait(let seconds):
                    await source.poll(seconds)
                }
            }
            switch transition.outcome {
            case .wait:
                continue
            case .keyframe(let frame):
                return frame
            case .displayed(let frame):
                return frame
            case .fail:
                throw boundFailure(id: id, state: state)
            }
        }
    }

    /// The frame on the display, when the answer may honestly claim it. It is
    /// read only once the phone has sent a `window.still` since this ask, so a
    /// moving window or a stale pre-call still never touches the display layer.
    /// A frame older than the call is still the picture then (MCP-61) and its
    /// `frame.ageMs` says how old it is, a static page left open for minutes
    /// being exactly what this route is for. Without a counted frame there is
    /// nothing to vouch for and the display is never read: a still is not a
    /// first picture (MCP-61). A keyframe arriving first wins by the machine's
    /// order.
    private static func displayedFrame(_ source: ScreenshotSource,
                                       askedAt: TimeInterval) -> SnapshotFrame? {
        guard ScreenshotWait.stillVouches(source.stillSince, askedAt: askedAt),
              let at = source.newestAt,
              let buffer = source.copyDisplayedFrame() else { return nil }
        return SnapshotFrame(buffer: buffer, seq: source.newestSeq, at: at, origin: .displayed)
    }

    /// At the bound: a window that closed while the call waited is gone, not
    /// short of a picture (MCP-61).
    private static func boundFailure(id: Int, state: () -> String) -> MCPToolError {
        let now = state()
        return now == "closed" ? MCPToolError.noWindow(id) : MCPToolError.noFrame(window: id, state: now)
    }
}

// MARK: - Blank (MCP-62)

enum ScreenshotBlank {
    /// Every cell of the frame's 16×16 luma grid within 2 levels of the others:
    /// a black or one-colour frame. The input probe's grid, no new image path.
    static func isBlank(_ buffer: CVPixelBuffer) -> Bool {
        guard let grid = ProbeSignal.signature(of: buffer, region: .whole),
              let low = grid.cells.min(), let high = grid.cells.max() else { return false }
        return Int(high) - Int(low) <= 2
    }
}

// MARK: - Ref crop (MCP-63)

enum ScreenshotCrop {
    /// The display pixels added on each side of a ref's box.
    static let margin = 8

    /// The ref's box plus the margin, clamped to `size` (the display pixels
    /// the tree's boxes are in, MCP-63), or the failure the
    /// ref maps to: `stale_ref` for a ref the latest tree does not name,
    /// `off_screen` for an off-screen node (the tap's own refusals).
    static func box(for resolution: UITreeResolution, ref: String, window: Int,
                    size frameSize: (Int, Int)) throws -> [Int] {
        if let refusal = MCPToolError.tapRefusal(resolution, ref: ref, window: window) {
            throw refusal
        }
        guard case .placed(_, let placed) = resolution, let box = placed.box, box.count == 4 else {
            throw MCPToolError(.offScreen, UITreeRefusal.offScreen(ref), ["window": window, "ref": ref])
        }
        return [max(0, box[0] - margin), max(0, box[1] - margin),
                min(frameSize.0, box[2] + margin), min(frameSize.1, box[3] + margin)]
    }

    /// The crop in the decoded frame's pixels: `crop` (display pixels, in a
    /// display of `size`) scaled by frame/size, widened to whole pixels and
    /// clamped to the frame.
    static func frameRect(crop: [Int], size: (Int, Int), frame: (Int, Int)) -> [Int] {
        guard crop.count == 4, size.0 > 0, size.1 > 0 else { return [0, 0, frame.0, frame.1] }
        func down(_ v: Int, _ f: Int, _ s: Int) -> Int { min(f, max(0, v * f / s)) }
        func up(_ v: Int, _ f: Int, _ s: Int) -> Int { min(f, max(0, (v * f + s - 1) / s)) }
        return [down(crop[0], frame.0, size.0), down(crop[1], frame.1, size.1),
                up(crop[2], frame.0, size.0), up(crop[3], frame.1, size.1)]
    }
}

// MARK: - The window's pixel space (MCP-50, MCP-62)

/// `size: [w, h]` in every answer is the pixel space of `ui_tree`'s `box`:
/// the phone display's pixels for that window. An app window's virtual display
/// is made at its stream's size; the Phone Mirror's display is the phone's
/// screen, larger than its stream (MIRROR-25).
enum MCPWindowSize {
    /// The latest tree's `size` when there is one; for the Phone Mirror the
    /// phone's screen turned to the stream's orientation; else the stream's.
    static func pixels(treeSize: [Int]?, mirrorScreen: CGSize?, stream: (Int, Int)) -> (Int, Int) {
        if let treeSize, treeSize.count == 2, treeSize[0] > 0, treeSize[1] > 0 {
            return (treeSize[0], treeSize[1])
        }
        if let mirrorScreen, mirrorScreen.width > 0, mirrorScreen.height > 0 {
            let short = Int(min(mirrorScreen.width, mirrorScreen.height).rounded())
            let long = Int(max(mirrorScreen.width, mirrorScreen.height).rounded())
            return stream.0 > stream.1 ? (long, short) : (short, long)
        }
        return stream
    }
}
