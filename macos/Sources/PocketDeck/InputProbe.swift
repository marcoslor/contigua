// P0 of the pmaxx epic: the input-to-photon probe. A tap goes out through the
// same path a person's click takes; a private decoder watches the stream's
// frames and the first one whose picture changed in the watched region is the
// answer. The machine is pure and clock-injected so every transition is a K2
// check; the decoder and the continuations are the view's.

import CoreVideo
import Foundation
import VideoToolbox

/// The watched part of the picture, in normalized coordinates (0…1, top-left).
struct ProbeRegion: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    /// The whole picture: a tap's effect anywhere is the answer.
    static let whole = ProbeRegion(x: 0, y: 0, width: 1, height: 1)

    /// A box around the tap, for a control whose change stays local.
    static func around(x: Double, y: Double, width: Double, height: Double) -> ProbeRegion {
        let w = min(max(width, 0.05), 1)
        let h = min(max(height, 0.05), 1)
        let left = min(max(x - w / 2, 0), 1 - w)
        let top = min(max(y - h / 2, 0), 1 - h)
        return ProbeRegion(x: left, y: top, width: w, height: h)
    }

    /// The region in a buffer of `size`, clipped to it.
    func rect(in size: CGSize) -> CGRect {
        let rect = CGRect(x: x * size.width, y: y * size.height,
                          width: width * size.width, height: height * size.height)
        return rect.intersection(CGRect(origin: .zero, size: size))
    }
}

/// A downsampled luma grid of the watched region: 16×16 bytes, independent of
/// the picture's size. Comparing two grids is comparing what a person sees.
struct ProbeSignature: Equatable {
    static let side = 16
    var cells: [UInt8]

    var meanAbsDifference: Int {
        cells.isEmpty ? 0 : cells.reduce(0) { $0 + Int($1) } / cells.count
    }
}

/// What one probe saw: whether a baseline arrived, how many frames the private
/// decoder delivered, and the input-to-picture time when one changed.
struct InputProbeOutcome: Equatable {
    let armed: Bool
    let changedMs: Double?
    let frames: Int
}
enum ProbeSignal {
    /// One luma grid from a 32BGRA pixel buffer. Nil for a missing base
    /// address or a zero-sized region: a measurement, never a crash.
    static func signature(of buffer: CVPixelBuffer, region: ProbeRegion) -> ProbeSignature? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rect = region.rect(in: CGSize(width: width, height: height))
        guard rect.width >= CGFloat(ProbeSignature.side), rect.height >= CGFloat(ProbeSignature.side) else {
            return nil
        }
        let side = ProbeSignature.side
        var cells = [UInt8](repeating: 0, count: side * side)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<side {
            for column in 0..<side {
                let px = Int(rect.minX) + (column * Int(rect.width)) / side
                let py = Int(rect.minY) + (row * Int(rect.height)) / side
                let offset = py * stride + px * 4
                let b = Int(bytes[offset])
                let g = Int(bytes[offset + 1])
                let r = Int(bytes[offset + 2])
                cells[row * side + column] = UInt8((299 * r + 587 * g + 114 * b) / 1000)
            }
        }
        return ProbeSignature(cells: cells)
    }

    /// A picture changed when its mean luma moved by 8 levels, or a fifth of
    /// its cells moved by 24: a page transition and a keyboard both pass, a
    /// compression flicker does not.
    static func changed(_ before: ProbeSignature, _ after: ProbeSignature) -> Bool {
        guard before.cells.count == after.cells.count, !before.cells.isEmpty else { return false }
        let differences = zip(before.cells, after.cells).map { abs(Int($0) - Int($1)) }
        let mean = differences.reduce(0, +) / differences.count
        let moved = differences.filter { $0 >= 24 }.count
        return mean >= 8 || moved * 5 >= differences.count
    }
}

enum InputProbePhase: String {
    case idle
    case waitingBaseline = "waiting_baseline"
    case watching
    case done
}

enum InputProbeEvent {
    case arm
    case frame(ProbeSignature, atMs: Double)
    case tapSent(atMs: Double)
    case deadline
}

enum InputProbeAction: Equatable {
    /// The baseline frame is in: the tap may go now.
    case armed
    /// The first changed frame arrived: the tap's effect is on the Mac.
    case changed(ms: Double)
    /// Nothing changed before the deadline.
    case timedOut
}

/// One probe's states and events. A tap is sent only after `.armed`; frames
/// before the tap set nothing; every event in `done` is ignored (AGENTS.md's
/// state-machine rule, and the field log prints each transition).
struct InputProbeModel {
    private(set) var phase: InputProbePhase = .idle
    private(set) var baseline: ProbeSignature?
    private(set) var sentAtMs: Double?
    private(set) var changedMs: Double?
    private(set) var frames = 0
    let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    private mutating func move(_ next: InputProbePhase, _ event: String) {
        guard next != phase else { return }
        log("input probe: \(phase.rawValue) --\(event)--> \(next.rawValue)")
        phase = next
    }

    mutating func handle(_ event: InputProbeEvent) -> InputProbeAction? {
        switch (phase, event) {
        case (.idle, .arm):
            move(.waitingBaseline, "arm")
            return nil
        case (.waitingBaseline, .frame(let signature, _)):
            baseline = signature
            frames += 1
            move(.watching, "baseline")
            return .armed
        case (.watching, .tapSent(let atMs)):
            guard sentAtMs == nil else { return nil }
            sentAtMs = atMs
            return nil
        case (.watching, .frame(let signature, let atMs)):
            frames += 1
            guard let sent = sentAtMs, atMs >= sent, let before = baseline else { return nil }
            guard ProbeSignal.changed(before, signature) else { return nil }
            changedMs = atMs - sent
            move(.done, "changed")
            return .changed(ms: changedMs ?? 0)
        case (.watching, .deadline):
            move(.done, "deadline")
            return .timedOut
        case (.waitingBaseline, .deadline):
            move(.done, "deadline")
            return .timedOut
        case (.waitingBaseline, .tapSent), (.idle, .tapSent):
            // The caller must wait for `.armed`; a tap before a baseline has
            // nothing to compare against and is ignored, never guessed.
            return nil
        case (.watching, .arm), (.waitingBaseline, .arm):
            return nil
        case (.done, _), (.idle, _):
            return nil
        }
    }
}

/// Decodes every frame of a probe window, unlike [KeyframeSnapshotter] which
/// stops at the first. Only alive for one probe (≤ a few seconds); it is the
/// only way to see the stream's own pixels before the display layer.
final class InputProbeDecoder {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var handler: ((CVPixelBuffer, Double) -> Void)?
    private var finished = true

    func begin(format: CMVideoFormatDescription,
               handler: @escaping (CVPixelBuffer, Double) -> Void) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { return }
        lock.lock()
        self.session = session
        self.handler = handler
        self.finished = false
        lock.unlock()
    }

    func feed(_ sample: CMSampleBuffer) {
        lock.lock()
        guard !finished, let session, let handler else { lock.unlock(); return }
        lock.unlock()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { status, _, image, _, _ in
            guard status == noErr, let image else { return }
            handler(image, ProcessInfo.processInfo.systemUptime * 1000)
        }
        if status != noErr {
            Log.video.debug("input probe: decode refused (\(status, privacy: .public))")
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let session = self.session
        self.session = nil
        self.handler = nil
        lock.unlock()
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
