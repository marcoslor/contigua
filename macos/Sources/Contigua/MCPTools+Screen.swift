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
        controller.windowActs.agentInput(window: UInt32(id), client: client)
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

/// A decoded frame from after the call, its count on the window's clock and
/// when it arrived (uptime). Its age is taken when the answer is made (MCP-20).
struct SnapshotFrame {
    let buffer: CVPixelBuffer
    let seq: Int
    let at: TimeInterval
}

/// What a screenshot reads its frame from: a window, or a fake in the tests.
/// `copyDisplayedFrame` is here so a fake can prove it is never read.
@MainActor
protocol ScreenshotSource: AnyObject {
    /// The newest counted frame when the call starts.
    var newestSeq: Int { get }
    /// Live Text's freeze holds the one snapshot decoder.
    var isCapturing: Bool { get }
    /// The display layer's buffer: never a screenshot's answer (MCP-60).
    func copyDisplayedFrame() -> CVPixelBuffer?
    /// The first keyframe counted after `seq`, decoded; nil after `timeout`.
    /// Called only once Live Text no longer holds the decoder.
    func nextKeyframe(after seq: Int, timeout: TimeInterval) async -> SnapshotFrame?
}

extension StreamWindowController: ScreenshotSource {
    var newestSeq: Int { frameClock.newest }

    var isCapturing: Bool { liveText.state == .capturing }

    func copyDisplayedFrame() -> CVPixelBuffer? { videoView.copyDisplayedFrame() }

    func nextKeyframe(after seq: Int, timeout: TimeInterval) async -> SnapshotFrame? {
        final class Once {
            var continuation: CheckedContinuation<SnapshotFrame?, Never>?
            func finish(_ frame: SnapshotFrame?) {
                continuation?.resume(returning: frame)
                continuation = nil
            }
        }
        let once = Once()
        let view = videoView
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            let token = view.beginFrameSnapshot(after: seq) { buffer, stamp in
                MainActor.assumeIsolated {
                    guard let buffer, let stamp else { once.finish(nil); return }
                    once.finish(SnapshotFrame(buffer: buffer, seq: stamp.seq, at: stamp.at))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard once.continuation != nil else { return }
                view.cancelFrameSnapshot(token)
                once.finish(nil)
            }
        }
    }
}

// MARK: - The answer (MCP-60…63)

@MainActor
enum Screenshot {
    /// The bound for a keyframe to arrive (MCP-61).
    static let timeout: TimeInterval = 2

    /// The `.image` answer for the first keyframe after the call, or `no_frame`.
    /// `state` is read when the answer or failure is made, not at the call:
    /// an opening window may have gone live, a live one stalled or closed.
    static func result(id: Int, state: () -> String, source: ScreenshotSource,
                       size: (Int, Int), crop: [Int]?,
                       online: Bool = true, phone: String? = nil,
                       encode: @escaping @Sendable (CVPixelBuffer, [Int]?) -> Data? = { FrameGrab.png(from: $0, crop: $1) })
        async throws -> MCPToolResult {
        // MCP-61: an offline window can make no picture; say so before asking.
        guard online else { throw MCPToolError.phoneOffline(phone) }
        let start = source.newestSeq
        // Live Text's freeze holds the one snapshot decoder: wait for it to
        // finish rather than take it away. The wait is inside the one 2 s
        // bound; the keyframe gets only the time left (MCP-61).
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while source.isCapturing, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let left = deadline - ProcessInfo.processInfo.systemUptime
        let frame = source.isCapturing || left <= 0
            ? nil : await source.nextKeyframe(after: start, timeout: left)
        guard let frame else {
            // MCP-61: a window that closed while the call waited is gone,
            // not short of a picture.
            let now = state()
            if now == "closed" { throw MCPToolError.noWindow(id) }
            throw MCPToolError.noFrame(window: id, state: now)
        }
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
        var answer: [String: Any] = [
            "window": id,
            "state": state(),
            // MCP-20: the age now, when the answer is made, not at decode.
            "frame": FrameClock.object(seq: frame.seq,
                                       ageMs: FrameClock.ms(since: frame.at,
                                                            now: ProcessInfo.processInfo.systemUptime)),
            "image": [image.0, image.1],
            "size": [size.0, size.1],
        ]
        if encoded.1 { answer["blank"] = true }
        if let crop { answer["crop"] = crop }
        return .image(png, answer)
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
