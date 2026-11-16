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
    func screenshot(_ id: Int, ref: String?) async throws -> MCPToolResult {
        let window = try requireWindow(id)
        let size = (Int(window.videoView.videoSize.width.rounded()),
                    Int(window.videoView.videoSize.height.rounded()))
        let crop = try ref.map {
            try ScreenshotCrop.box(for: controller.uiTreeResolved(ref: $0, stream: window.stream),
                                   ref: $0, window: id, size: size)
        }
        do {
            let result = try await Screenshot.result(id: id, state: { self.stateToken(for: window) },
                                                     source: window, size: size, crop: crop,
                                                     online: controller.link.isOnline, phone: phoneName)
            // MCP-21: the state as it is when the answer is made. A window's
            // first frame can end its opening while the call waits for it.
            guard case .image(let png, var answer) = result else { return result }
            answer["state"] = stateToken(for: window)
            return .image(png, answer)
        } catch let error as MCPToolError where error.code == .noFrame {
            // The state at the bound, not at the call: an opening window may
            // have gone live, a live one may have stalled.
            throw MCPToolError.noFrame(window: id, state: stateToken(for: window))
        }
    }

    /// P0 (pmaxx): the tap goes through the same session path a click does;
    /// the probe's private decoder watches the stream's frames and reports the
    /// first one that changed. `changed_ms` is from the send to that frame's
    /// decode; the display layer shows it on the next refresh (≤ 16.7 ms at
    /// 60 Hz), so the tool's number is the input-to-picture part of
    /// input-to-photon.
    func inputProbe(window id: Int, x: Double, y: Double,
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

/// A decoded frame from after the call and its count on the window's clock.
struct SnapshotFrame {
    let buffer: CVPixelBuffer
    let seq: Int
    let at: TimeInterval?
    var ageMs: Int? = nil
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
    func nextKeyframe(after seq: Int, timeout: TimeInterval) async -> SnapshotFrame?
}

extension StreamWindowController: ScreenshotSource {
    var newestSeq: Int { frameClock.newest }

    var isCapturing: Bool { liveText.state == .capturing }

    func copyDisplayedFrame() -> CVPixelBuffer? { videoView.copyDisplayedFrame() }

    func nextKeyframe(after seq: Int, timeout: TimeInterval) async -> SnapshotFrame? {
        // Live Text's freeze holds the one snapshot decoder: wait for it to
        // finish (at most the same bound) rather than take it away.
        let start = ProcessInfo.processInfo.systemUptime
        while liveText.state == .capturing,
              ProcessInfo.processInfo.systemUptime - start < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard liveText.state != .capturing else { return nil }
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
            view.beginFrameSnapshot(after: seq) { buffer, stamp in
                MainActor.assumeIsolated {
                    guard let buffer, let stamp else { once.finish(nil); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    once.finish(SnapshotFrame(buffer: buffer, seq: stamp.seq, at: stamp.at,
                                              ageMs: FrameClock.ms(since: stamp.at, now: now)))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard once.continuation != nil else { return }
                view.cancelFrameSnapshot()
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
    static func result(id: Int, state: () -> String, source: ScreenshotSource,
                       size: (Int, Int), crop: [Int]?,
                       online: Bool = true, phone: String? = nil,
                       encode: @escaping @Sendable (CVPixelBuffer, [Int]?) -> Data? = { FrameGrab.png(from: $0, crop: $1) })
        async throws -> MCPToolResult {
        let state = state()
        let streamSize = size
        // MCP-61: an offline window can make no picture; say so before asking.
        guard online else { throw MCPToolError.phoneOffline(phone) }
        let start = source.newestSeq
        guard let frame = await source.nextKeyframe(after: start, timeout: timeout) else {
            throw MCPToolError.noFrame(window: id, state: state)
        }
        let buffer = frame.buffer
        let encoded = await Task.detached(priority: .userInitiated) { () -> (Data?, Bool) in
            (encode(buffer, crop), ScreenshotBlank.isBlank(buffer))
        }.value
        guard let png = encoded.0 else { throw MCPToolError.noFrame(window: id, state: state) }
        let image = FrameGrab.scaledSize(sourceWidth: CVPixelBufferGetWidth(buffer),
                                         sourceHeight: CVPixelBufferGetHeight(buffer), crop: crop)
        var answer: [String: Any] = [
            "window": id,
            "state": state,
            "frame": FrameClock.object(seq: frame.seq, ageMs: frame.ageMs),
            "image": [image.0, image.1],
            "size": [streamSize.0, streamSize.1],
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
    /// The window pixels added on each side of a ref's box.
    static let margin = 8

    /// The ref's box plus the margin, clamped to the frame, or the failure the
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

    /// The crop in the decoded frame's pixels.
    static func frameRect(crop: [Int], size: (Int, Int), frame: (Int, Int)) -> [Int] { crop }
}

// MARK: - The window's pixel space (MCP-50, MCP-62)

enum MCPWindowSize {
    static func pixels(treeSize: [Int]?, mirrorScreen: CGSize?, stream: (Int, Int)) -> (Int, Int) { stream }
}
