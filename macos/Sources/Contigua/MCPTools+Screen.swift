// screenshot and input_probe (docs/design/mcp.md, MCP-60…64, MCP-99).

import AVFoundation
import Foundation

extension MCPToolHost {
    // MARK: Screenshot

    func screenshot(_ id: Int) async throws -> MCPToolResult {
        let window = try requireWindow(id)
        // The same two routes as Live Text's freeze: the frame the display
        // layer shows (what the person sees), else the phone's next keyframe
        // decoded once, for a window whose layer reports no displayed buffer
        // (occluded, or a quiet/headless run).
        if let buffer = window.videoView.copyDisplayedFrame(),
           let data = await encode(buffer) {
            return .image(data, ["window": id])
        }
        if let buffer = await snapshot(window), let data = await encode(buffer) {
            return .image(data, ["window": id])
        }
        throw MCPToolError.noFrame(window: id, state: controller.link.isOnline ? "live" : "offline")
    }

    func encode(_ buffer: CVPixelBuffer) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            FrameGrab.png(from: buffer)
        }.value
    }

    /// The phone's next keyframe, decoded (VideoLayerView.beginFrameSnapshot).
    /// nil after 2 s: no format yet, the phone is gone, or Live Text took the
    /// decoder for its own freeze in the meantime.
    func snapshot(_ window: StreamWindowController) async -> CVPixelBuffer? {
        final class Once {
            var continuation: CheckedContinuation<CVPixelBuffer?, Never>?
            func finish(_ buffer: CVPixelBuffer?) {
                continuation?.resume(returning: buffer)
                continuation = nil
            }
        }
        let once = Once()
        let view = window.videoView
        let buffer = await withCheckedContinuation { continuation in
            once.continuation = continuation
            view.beginFrameSnapshot { buffer in MainActor.assumeIsolated { once.finish(buffer) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {  // gcd: moved unchanged from MCPTools.swift (T1 split)
                MainActor.assumeIsolated {
                    guard once.continuation != nil else { return }
                    view.cancelFrameSnapshot()
                    once.finish(nil)
                }
            }
        }
        return buffer
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
