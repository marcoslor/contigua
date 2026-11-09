// The cover a stream window shows from the moment it opens until its first
// frame (docs/UX.md "Opening a window", the L1 design): a large app icon on the
// shared frosted cover (WIN-63), a 2 pt accent line sweeping under the title bar
// and the title "<App> — opening on <phone>". At 5 s a secondary line and a
// glass capsule Cancel join it; the phone's refusal or 20 s brings the grey
// icon, one sentence and a reason line, with Close alone. The phone window wears
// the same cover with "phone screen" wording.
//
// One explicit machine: a closed set of states, the events it accepts and a
// pure transition that returns actions (AGENTS.md). The controller runs the
// actions, logs each transition and drives the view.

import AppKit
import CoreImage

struct OpeningCover: Equatable {
    /// What the cover shows now.
    enum Phase: Equatable {
        case opening
        case slow
        case failed(reason: String?)
    }

    /// The machine's closed states. `live` and `closed` both mean the cover is
    /// over, but one is the first frame and the other the person's Cancel.
    enum State: Equatable {
        case opening
        case slow
        case failed(reason: String?)
        case live
        case closed
    }

    enum Event: Equatable {
        /// The clock moved.
        case tick(TimeInterval)
        /// The stream's first frame arrived.
        case firstFrame
        /// The phone refused the open with this `error` code.
        case refused(String)
        /// The person pressed Cancel.
        case cancel
    }

    /// Side effects the caller runs; the transition performs none.
    enum Action: Equatable {
        case closeWindow
    }

    static let slowAfter: TimeInterval = 5
    static let failAfter: TimeInterval = 20

    let startedAt: TimeInterval
    private(set) var state: State = .opening

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    var isUp: Bool {
        switch state {
        case .opening, .slow, .failed: return true
        case .live, .closed: return false
        }
    }

    /// The phase on screen, or nil once the cover is over. The clock-driven
    /// part is derived from `startedAt` as well as from the machine's ticks, so
    /// a state read between two ticks is never a stale phase.
    func phase(at time: TimeInterval) -> Phase? {
        switch state {
        case .opening, .slow:
            let elapsed = time - startedAt
            if elapsed >= Self.failAfter { return .failed(reason: nil) }
            if elapsed >= Self.slowAfter { return .slow }
            return .opening
        case .failed(let reason):
            return .failed(reason: reason)
        case .live, .closed:
            return nil
        }
    }

    /// The machine's one transition. `nil` means the event is ignored in this
    /// state (the same state and no actions): the caller then logs nothing.
    @discardableResult
    mutating func handle(_ event: Event, at now: TimeInterval) -> [Action]? {
        let (next, actions) = Self.transition(state, event, startedAt: startedAt, now: now)
        guard next != state else { return nil }
        state = next
        return actions
    }

    static func transition(_ state: State, _ event: Event,
                           startedAt: TimeInterval, now: TimeInterval) -> (State, [Action]) {
        switch state {
        case .live, .closed:
            // A finished window has no cover to move.
            return (state, [])
        case .failed:
            switch event {
            case .firstFrame:
                // The picture came after all: the cover goes.
                return (.live, [])
            case .refused:
                // The first refusal is the one the window reports.
                return (state, [])
            case .tick, .cancel:
                return (state, [])
            }
        case .opening:
            switch event {
            case .tick(let time):
                let elapsed = time - startedAt
                if elapsed >= failAfter { return (.failed(reason: nil), []) }
                if elapsed >= slowAfter { return (.slow, []) }
                return (state, [])
            case .firstFrame:
                return (.live, [])
            case .refused(let code):
                return (.failed(reason: reason(for: code)), [])
            case .cancel:
                return (.closed, [.closeWindow])
            }
        case .slow:
            switch event {
            case .tick(let time):
                if time - startedAt >= failAfter { return (.failed(reason: nil), []) }
                return (state, [])
            case .firstFrame:
                return (.live, [])
            case .refused(let code):
                return (.failed(reason: reason(for: code)), [])
            case .cancel:
                return (.closed, [.closeWindow])
            }
        }
    }

    /// The reason line for a phone `error` code, or nil when the code is not
    /// one the cover can explain (no reason line, never a raw code).
    static func reason(for code: String) -> String? {
        switch code {
        case "app_disabled": return "The app is disabled on the phone."
        case "app_missing", "not_installed": return "The app isn't installed any more."
        case "mirror_unavailable": return "This phone can't share its screen with PocketDeck."
        case "launch_failed", "bad_request", "bad_size", "no_stream", "internal": return nil
        default: return nil
        }
    }

    /// "<App> — opening on <phone>": what the cover's own title says.
    static func title(name: String, phone: String, phoneMode: Bool) -> String {
        let subject = phoneMode ? "Phone" : name
        let place = phone.isEmpty ? "your phone" : phone
        return "\(subject) — opening on \(place)"
    }

    /// The failure's one sentence, in the app's or the mirror's wording.
    static func lead(name: String, phone: String, phoneMode: Bool) -> String {
        let place = phone.isEmpty ? "your phone" : phone
        return phoneMode ? "\(place) can't open the phone screen."
                         : "\(place) can't open \(name)."
    }

    /// What a state shows, as the view draws it. nil once the cover is over.
    struct Display: Equatable {
        var phase: Phase
        var title: String
        var secondary: String?
        var lead: String?
        var reason: String?
        var showsCancel: Bool
        var showsClose: Bool
    }

    static func display(_ phase: Phase?, name: String, phone: String, phoneMode: Bool) -> Display? {
        guard let phase else { return nil }
        switch phase {
        case .opening:
            return Display(phase: phase, title: title(name: name, phone: phone, phoneMode: phoneMode),
                           secondary: nil, lead: nil, reason: nil, showsCancel: false, showsClose: false)
        case .slow:
            return Display(phase: phase, title: title(name: name, phone: phone, phoneMode: phoneMode),
                           secondary: "Taking longer than usual", lead: nil, reason: nil,
                           showsCancel: true, showsClose: false)
        case .failed(let reason):
            return Display(phase: phase, title: title(name: name, phone: phone, phoneMode: phoneMode),
                           secondary: nil,
                           lead: lead(name: name, phone: phone, phoneMode: phoneMode),
                           reason: reason, showsCancel: false, showsClose: true)
        }
    }

    /// The state's name for the transition log.
    static func label(_ state: State) -> String {
        switch state {
        case .opening: return "opening"
        case .slow: return "slow"
        case .failed: return "failed"
        case .live: return "live"
        case .closed: return "closed"
        }
    }
}
/// The L1 cover drawn by the shared cover (FrostedCover, WIN-63): the app's
/// icon, the accent sweep, the title and the slow or refused words. A click
/// that is not a button is swallowed: the phone sees nothing while it is up.
final class OpeningCoverView: FrostedCoverView {
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    private var display: OpeningCover.Display?
    private var failureLead = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows what the machine says, or takes the cover away (nil: the picture
    /// is in or the person closed it). `heldFrame` is the picture displayed
    /// when the cover arrives; the shared view blurs it.
    func show(_ display: OpeningCover.Display?, icon: NSImage?, heldFrame: CVPixelBuffer? = nil) {
        self.display = display
        guard let display else {
            failureLead = ""
            super.show(nil)
            return
        }
        var failed = false
        if case .failed = display.phase { failed = true }
        // Before the app's icon has arrived (or for an app with none), a
        // generic app mark keeps the cover's one large picture.
        let picture: NSImage? = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        if failed {
            failureLead = display.lead ?? ""
            // A real app icon keeps its shape without its colour; a symbol is
            // a template and greys with its tint instead.
            let shown = picture?.isTemplate == false ? picture?.greyed() : picture
            super.show(FrostedCoverContent(title: display.lead ?? "",
                                           line: display.reason,
                                           button: display.showsClose ? "Close" : nil,
                                           icon: shown,
                                           showsIcon: true,
                                           iconIsDimmed: true,
                                           showsSweep: false), heldFrame: heldFrame)
            onPrimary = { [weak self] in self?.onClose?() }
        } else {
            failureLead = ""
            super.show(FrostedCoverContent(title: display.title,
                                           line: display.secondary,
                                           button: display.showsCancel ? "Cancel" : nil,
                                           icon: picture,
                                           showsIcon: true,
                                           iconIsDimmed: false,
                                           showsSweep: true), heldFrame: heldFrame)
            onPrimary = { [weak self] in self?.onCancel?() }
        }
    }

    /// The sentence on screen: the e2e's proof that the failure is the
    /// documented one, not a generic message.
    var displayedMessage: String { failureLead }
    var displayedTitle: String { failureLead.isEmpty ? titleText : "" }
    var displayedSecondary: String { display?.secondary ?? "" }
    var displayedReason: String { display?.reason ?? "" }

    /// The sentence's drawn frame and the buttons that are up: the layout tests
    /// read them (a failure's sentence wraps, and Close alone is centred).
    var messageFrame: NSRect { titleFrame }
    var messageText: String { failureLead }
    var visibleButtonFrames: [NSRect] { buttonFrame.map { [$0] } ?? [] }
}

private extension NSImage {
    /// The failure's grey icon: the same picture without its colour.
    func greyed() -> NSImage {
        guard let tiff = tiffRepresentation, let input = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return self }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return self }
        return NSImage(cgImage: cgImage, size: size)
    }
}
