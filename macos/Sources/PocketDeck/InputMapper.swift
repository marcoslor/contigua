// NSEvent -> protocol message mapping. Nothing is coalesced except ASCII text,
// which is batched for up to 8 ms so a fast typist produces one `text` frame
// instead of one per character, and the moves of the coarse pinch emulation,
// which are held to at most one per display refresh. Touch/scroll/keys are sent
// immediately.

import AppKit

final class InputMapper {
    enum Command {
        case touch(TouchEvent)
        case scroll(ScrollEvent)
        case hover(HoverEvent)
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

    /// Which Android nav action a mouse-button press maps to (NSEvent
    /// buttonNumber for otherMouseDown): the middle button (2) is home, the
    /// usual side Back button (3) is back. Forward (4) and anything else do
    /// nothing. Only the down event maps, so one press is one Back — never
    /// repeated while held and nothing on mouse-up.
    static func navAction(forButton button: Int) -> String? {
        switch button {
        case 2: return "home"
        case 3: return "back"
        default: return nil
        }
    }

    /// Which Android nav action a swipe event maps to: mouse utilities (e.g.
    /// Logi Options+) deliver a Back button as NSEvent type .swipe instead of
    /// otherMouseDown, with deltaX = +1 for back and −1 for forward. Forward
    /// stays inert.
    static func navAction(forSwipeDeltaX deltaX: CGFloat) -> String? {
        deltaX > 0 ? "back" : nil
    }

    let stream: UInt32
    var send: ((Command) -> Void)?
    var videoRectProvider: () -> CGRect = { .zero }
    var locationProvider: (NSEvent) -> CGPoint = { _ in .zero }
    var viewIsFlipped: () -> Bool = { false }
    /// Phone-mode windows add ⇧⌘H (home) and ⌘↑ (recents).
    var isPhoneMode = false
    /// Esc reaches the phone only from the focused window with no sheet open.
    var escapeAllowed: () -> Bool = { true }
    /// Video pixel size; the gesture geometry keeps its aspect ratio.
    var videoSizeProvider: () -> CGSize = { .zero }
    /// Live Text mode (LiveTextMode.swift): while it is on, nothing goes to the
    /// phone — pointer, keys, scroll, hover, trackpad. Esc leaves the mode
    /// instead of reaching Android.
    var inputSuspended: () -> Bool = { false }
    var onLiveTextEscape: (() -> Void)?
    private var suspended: Bool { inputSuspended() }
    /// A mouse button in use (a click-drag) wins: gestures are ignored then.
    var mouseButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    /// Schedules the coalesced gesture move. The default waits one display
    /// refresh on the main run loop; tests and the scripted-input driver drive
    /// it by hand.
    var scheduleGestureMove: (@escaping () -> Void) -> Void = { work in
        InputMapper.onMainRunLoop(after: InputMapper.displayRefreshInterval, work)
    }
    /// Schedules the second tap of a smart zoom a moment after the first, so
    /// the phone's tap detector counts two taps.
    var scheduleSecondTap: (@escaping () -> Void) -> Void = { work in
        InputMapper.onMainRunLoop(after: InputMapper.doubleTapInterval, work)
    }

    /// A one-shot timer, not a main-queue block: timers still fire while the
    /// scripted driver runs a nested run loop between gesture steps, dispatch
    /// blocks queued on the busy main queue do not.
    static func onMainRunLoop(after delay: TimeInterval, _ work: @escaping () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in work() }
        RunLoop.main.add(timer, forMode: .common)
    }

    static let keyCodeEscape: UInt16 = 53
    static let keyCodeH: UInt16 = 4
    static let keyCodeUpArrow: UInt16 = 126

    private var scrollMapping = ScrollMapping()
    private var gestures = TrackpadGestures()

    /// The pointers a trackpad gesture is holding on the phone, for the Show
    /// Touches overlay (normalized video coordinates). Empty when none is down.
    var touchPointsChanged: (([TouchPoint]) -> Void)?
    private var livePointers: [UInt8: TouchPoint] = [:]
    /// The mouse-made touch the phone is holding (a click-drag in progress).
    private var mouseTouch: (nx: Float, ny: Float)?

    struct TouchPoint: Equatable {
        var id: UInt8
        var nx: Float
        var ny: Float
    }
    private var pendingText = ""
    private var textFlush: DispatchWorkItem?

    init(stream: UInt32) { self.stream = stream }

    // MARK: Geometry

    func normalized(_ point: CGPoint) -> (nx: Float, ny: Float) {
        Letterbox.normalized(point: point, videoRect: videoRectProvider(), flipped: viewIsFlipped())
    }

    // MARK: Mouse

    func mouseDown(_ event: NSEvent) {
        guard !suspended else { return }
        flushText()
        cancelTrackpadGestures()
        // A button down ends the hover before the touch starts.
        hoverExit()
        let (nx, ny) = normalized(locationProvider(event))
        LatencyLog.shared.noteTouchDown(stream: stream)
        mouseTouch = (nx, ny)
        send?(.touch(TouchEvent(action: .down, nx: nx, ny: ny)))
    }

    func mouseDragged(_ event: NSEvent) {
        guard !suspended else { return }
        let (nx, ny) = normalized(locationProvider(event))
        mouseTouch = (nx, ny)
        send?(.touch(TouchEvent(action: .move, nx: nx, ny: ny)))
    }

    func mouseUp(_ event: NSEvent) {
        guard !suspended else { return }
        let (nx, ny) = normalized(locationProvider(event))
        mouseTouch = nil
        send?(.touch(TouchEvent(action: .up, nx: nx, ny: ny)))
    }

    // MARK: Hover

    /// Settings ▸ Input "Hover over Android apps". Off sends no hover frames.
    var hoverEnabled: () -> Bool = { true }
    /// At most one hover move per this interval; the latest point wins.
    static let hoverMoveInterval: TimeInterval = 0.016
    /// Schedules the coalesced hover move; tests and the scripted driver drive
    /// it by hand.
    var scheduleHoverMove: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        InputMapper.onMainRunLoop(after: delay, work)
    }
    /// Monotonic clock for the 16 ms window; tests replace it.
    var hoverClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var hoverActive = false
    private var hoverLastPoint: (nx: Float, ny: Float) = (0, 0)
    private var hoverPending: (nx: Float, ny: Float)?
    private var hoverMoveScheduled = false
    private var hoverLastSent: TimeInterval = 0
    private var hoverGeneration = 0

    /// The pointer is over the video (a move, not a drag): the first one sends
    /// ENTER, the rest are MOVEs held to one per 16 ms.
    func hoverMove(at point: CGPoint) {
        guard !suspended else { return }
        guard hoverEnabled() else {
            // Off means no hover frames at all; the phone keeps whatever it
            // had until the setting comes back and a move sends ENTER again.
            hoverActive = false
            hoverPending = nil
            hoverGeneration += 1
            return
        }
        let (nx, ny) = normalized(point)
        guard hoverActive else {
            hoverActive = true
            hoverLastSent = hoverClock()
            hoverPending = nil
            sendHover(.enter, nx: nx, ny: ny)
            return
        }
        hoverPending = (nx, ny)
        let elapsed = hoverClock() - hoverLastSent
        if elapsed >= Self.hoverMoveInterval {
            flushHoverMove()
        } else if !hoverMoveScheduled {
            hoverMoveScheduled = true
            hoverGeneration += 1
            let generation = hoverGeneration
            scheduleHoverMove(Self.hoverMoveInterval - elapsed) { [weak self] in
                guard let self, generation == self.hoverGeneration else { return }
                self.flushHoverMove()
            }
        }
    }

    /// The pointer left the video (or the window), a button went down, the
    /// window lost key or closed, or it entered Mac UI drawn over the video.
    func hoverExit() {
        guard !suspended else { return }
        hoverPending = nil
        hoverMoveScheduled = false
        hoverGeneration += 1
        guard hoverActive else { return }
        hoverActive = false
        sendHover(.exit, nx: hoverLastPoint.nx, ny: hoverLastPoint.ny)
    }

    private func flushHoverMove() {
        hoverMoveScheduled = false
        guard hoverActive, let pending = hoverPending else { return }
        hoverPending = nil
        hoverLastSent = hoverClock()
        sendHover(.move, nx: pending.nx, ny: pending.ny)
    }

    private func sendHover(_ action: HoverAction, nx: Float, ny: Float) {
        hoverLastPoint = (nx, ny)
        send?(.hover(HoverEvent(action: action, nx: nx, ny: ny)))
    }

    /// Settings ▸ Input "Secondary click (two-finger click)" (SecondaryClick).
    var secondaryClick: () -> SecondaryClick = { .longPress }
    /// Android's long-press timeout (500 ms) plus a margin: the touch must
    /// stay down that long for the phone to open its context menu.
    static let secondaryLongPressDelay: TimeInterval = 0.6
    /// Schedules the end of the minimum hold; tests call the block directly.
    var scheduleSecondaryLongPress: (@escaping () -> Void) -> Void = { work in
        InputMapper.onMainRunLoop(after: InputMapper.secondaryLongPressDelay, work)
    }
    private var secondaryTouch: (nx: Float, ny: Float)?
    private var secondaryPendingMove: (nx: Float, ny: Float)?
    private var secondaryReleased = false
    private var secondaryReady = false

    func rightMouseDown(_ event: NSEvent) {
        guard !suspended else { return }
        flushText()
        cancelTrackpadGestures()
        hoverExit()
        switch secondaryClick() {
        case .back:
            send?(.nav("back"))
        case .nothing:
            break
        case .longPress:
            let (nx, ny) = normalized(locationProvider(event))
            startSecondaryTouch(nx: nx, ny: ny)
        }
    }

    /// The secondary button moved while held: after the long press it moves
    /// the touch; before it, the point is held for the long-press moment (a
    /// move in the first 600 ms would cancel Android's own detector).
    func rightMouseDragged(_ event: NSEvent) {
        guard !suspended, secondaryTouch != nil else { return }
        let (nx, ny) = normalized(locationProvider(event))
        secondaryTouch = (nx, ny)
        if secondaryReady {
            send?(.touch(TouchEvent(action: .move, nx: nx, ny: ny)))
        } else {
            secondaryPendingMove = (nx, ny)
        }
    }

    /// The button came up: a quick two-finger click still becomes a long press
    /// (the touch is held to the timeout), a held one ends at once.
    func rightMouseUp(_ event: NSEvent) {
        guard !suspended, secondaryTouch != nil else { return }
        let (nx, ny) = normalized(locationProvider(event))
        secondaryTouch = (nx, ny)
        if secondaryReady {
            finishSecondaryTouch()
        } else {
            // The point is in `secondaryTouch`: the hold ends there, with no
            // move of its own.
            secondaryReleased = true
        }
    }

    private func startSecondaryTouch(nx: Float, ny: Float) {
        secondaryTouch = (nx, ny)
        secondaryPendingMove = nil
        secondaryReleased = false
        secondaryReady = false
        LatencyLog.shared.noteTouchDown(stream: stream)
        send?(.touch(TouchEvent(action: .down, nx: nx, ny: ny)))
        scheduleSecondaryLongPress { [weak self] in self?.secondaryLongPressReached() }
    }

    private func secondaryLongPressReached() {
        guard secondaryTouch != nil else { return }
        secondaryReady = true
        if let pending = secondaryPendingMove {
            secondaryPendingMove = nil
            send?(.touch(TouchEvent(action: .move, nx: pending.nx, ny: pending.ny)))
        }
        if secondaryReleased { finishSecondaryTouch() }
    }

    private func finishSecondaryTouch() {
        guard let point = secondaryTouch else { return }
        secondaryTouch = nil
        secondaryPendingMove = nil
        secondaryReleased = false
        secondaryReady = false
        send?(.touch(TouchEvent(action: .up, nx: point.nx, ny: point.ny)))
    }

    /// Middle button -> home, side button 3 -> back (button 4, Forward, is inert).
    func otherMouseDown(_ event: NSEvent) {
        guard !suspended else { return }
        flushText()
        cancelTrackpadGestures()
        hoverExit()
        if let action = Self.navAction(forButton: Int(event.buttonNumber)) {
            send?(.nav(action))
        }
    }

    /// A swipe-back NSEvent from mouse utilities -> one Back, exactly like the
    /// button press. The delta is the seam: NSEvent cannot synthesize a .swipe,
    /// so unit tests drive this directly.
    func swipe(deltaX: CGFloat) {
        guard !suspended else { return }
        flushText()
        cancelTrackpadGestures()
        if let action = Self.navAction(forSwipeDeltaX: deltaX) {
            send?(.nav(action))
        }
    }

    /// Two-finger swipe from the window's left edge (see EdgeSwipeClassifier).
    func edgeSwipeBack() {
        guard !suspended else { return }
        flushText()
        send?(.nav("back"))
    }

    func scrollWheel(_ event: NSEvent) {
        scroll(ScrollSample(phase: event.phase, momentum: event.momentumPhase,
                            precise: event.hasPreciseScrollingDeltas,
                            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY)),
               at: locationProvider(event))
    }

    /// A wheel stays a SCROLL frame; a two-finger trackpad scroll becomes a
    /// one-finger drag (see ScrollDrag and TrackpadGestures).
    func scroll(_ sample: ScrollSample, at point: CGPoint) {
        guard !suspended else { return }
        flushText()
        let output = gestures.scroll(sample, cursor: point, space: gestureSpace)
        if output.wheel {
            guard let units = scrollMapping.map(deltaX: sample.deltaX, deltaY: sample.deltaY,
                                                precise: sample.precise, phase: sample.phase) else { return }
            let (nx, ny) = normalized(point)
            send?(.scroll(ScrollEvent(nx: nx, ny: ny, hscroll: units.hscroll, vscroll: units.vscroll)))
        }
        sendTrackpad(output.touches)
    }

    // MARK: Raw trackpad fingers

    private var gestureSpace: TrackpadGestures.Space {
        TrackpadGestures.Space(videoRect: videoRectProvider(), flipped: viewIsFlipped())
    }

    /// The fingers on the trackpad (NSTouch, resting ones left out), with the
    /// cursor in view points.
    func trackpadFingers(_ fingers: [TrackpadFinger], surface: TrackpadSurface, cursor: CGPoint) {
        guard !suspended else { return }
        if gestures.fingerCount < 2, fingers.count >= 2 { flushText() }
        sendTrackpad(gestures.fingersChanged(fingers, surface: surface, cursor: cursor, space: gestureSpace))
    }

    /// A click, a key window change or anything else that takes the stream
    /// from a trackpad gesture: Android is told to drop the touch.
    func cancelTrackpadGestures() {
        guard !suspended else { return }
        sendTrackpad(gestures.cancel())
        if pointerGesture != nil { finishGesture(cancelled: true) }
    }

    /// Trackpad-made touches go through here so the overlay knows what the
    /// phone is holding.
    private func sendTrackpad(_ events: [TouchEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            if event.action == .down, event.pointerId == 0 { LatencyLog.shared.noteTouchDown(stream: stream) }
            send?(.touch(event))
            switch event.action {
            case .down, .move:
                livePointers[event.pointerId] = TouchPoint(id: event.pointerId, nx: event.nx, ny: event.ny)
            case .up, .cancel:
                livePointers[event.pointerId] = nil
            }
        }
        touchPointsChanged?(livePointers.values.sorted { $0.id < $1.id })
    }

    // MARK: Trackpad gestures

    /// One gesture move per display refresh at most, like the mouse-drag stream
    /// AppKit already coalesces.
    static var displayRefreshInterval: TimeInterval {
        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        return fps > 0 ? 1 / TimeInterval(fps) : 1.0 / 60.0
    }

    /// Between the two taps of a smart zoom: above a tap detector's minimum
    /// double-tap time, well below its timeout.
    static let doubleTapInterval: TimeInterval = 0.05

    private enum GestureComponent { case magnify, rotate }

    private var pointerGesture: PointerGesture?
    /// Gesture kinds seen in the active gesture; it ends when they all have.
    private var gestureComponents: Set<GestureComponent> = []
    private var pendingGestureMove: (zero: (nx: Float, ny: Float), one: (nx: Float, ny: Float))?
    private var gestureMoveScheduled = false

    func magnify(phase: NSEvent.Phase, magnification: CGFloat, at point: CGPoint) {
        guard !suspended, !fingersOwnPinch() else { return }
        gesture(.magnify, phase: phase, delta: Double(magnification), at: point)
    }

    func rotate(phase: NSEvent.Phase, rotation: CGFloat, at point: CGPoint) {
        guard !suspended, !fingersOwnPinch() else { return }
        gesture(.rotate, phase: phase, delta: Double(rotation), at: point)
    }

    /// With two raw fingers on the trackpad the pointers come from them, not
    /// from the magnify and rotate events that describe the same gesture; the
    /// events only settle a pinch the fingers have not classified yet. Without
    /// raw fingers (no trackpad, or a view that gets no touches) the coarse
    /// emulation below stays the way a pinch reaches the phone.
    private func fingersOwnPinch() -> Bool {
        guard gestures.fingerCount >= 2 else { return false }
        sendTrackpad(gestures.pinchHinted(space: gestureSpace))
        return true
    }

    private func gesture(_ component: GestureComponent, phase: NSEvent.Phase,
                         delta: Double, at point: CGPoint) {
        if phase.contains(.cancelled) {
            finishGesture(cancelled: true)
            return
        }
        if phase.contains(.ended) {
            guard pointerGesture != nil else { return }
            gestureComponents.remove(component)
            if gestureComponents.isEmpty { finishGesture(cancelled: false) }
            return
        }
        guard phase.contains(.began) || phase.contains(.changed) else { return }
        if pointerGesture == nil {
            // An ongoing mouse drag owns the stream; a pinch during it is not ours.
            guard phase.contains(.began), !mouseButtonIsDown() else { return }
            startGesture(at: point)
        }
        guard pointerGesture != nil else { return }
        // Magnify and rotate run as separate began/ended sequences over one
        // pair of pointers.
        gestureComponents.insert(component)
        switch component {
        case .magnify: pointerGesture?.add(magnification: delta)
        case .rotate: pointerGesture?.add(rotation: delta)
        }
        if phase.contains(.changed) { queueGestureMove() }
    }

    private func startGesture(at point: CGPoint) {
        flushText()
        let (nx, ny) = normalized(point)
        pointerGesture = PointerGesture(anchorNx: Double(nx), anchorNy: Double(ny),
                                        videoSize: videoSizeProvider())
        gestureComponents = []
        pendingGestureMove = nil
        guard let points = pointerGesture?.points else { return }
        sendTrackpad([TouchEvent(action: .down, pointerId: 0, nx: points.zero.nx, ny: points.zero.ny),
                      TouchEvent(action: .down, pointerId: 1, nx: points.one.nx, ny: points.one.ny)])
    }

    /// Holds the latest geometry until the next display refresh; a burst of
    /// changed events still costs one move per pointer.
    private func queueGestureMove() {
        guard let gesture = pointerGesture else { return }
        pendingGestureMove = gesture.points
        guard !gestureMoveScheduled else { return }
        gestureMoveScheduled = true
        scheduleGestureMove { [weak self] in self?.flushGestureMove() }
    }

    private func flushGestureMove() {
        gestureMoveScheduled = false
        guard let points = pendingGestureMove else { return }
        pendingGestureMove = nil
        sendTrackpad([TouchEvent(action: .move, pointerId: 0, nx: points.zero.nx, ny: points.zero.ny),
                      TouchEvent(action: .move, pointerId: 1, nx: points.one.nx, ny: points.one.ny)])
    }

    private func finishGesture(cancelled: Bool) {
        guard let gesture = pointerGesture else { return }
        let points = gesture.points
        pointerGesture = nil
        gestureComponents = []
        flushGestureMove() // the last changed move may still be pending; it precedes the ups
        let action: TouchAction = cancelled ? .cancel : .up
        sendTrackpad([TouchEvent(action: action, pointerId: 1, nx: points.one.nx, ny: points.one.ny),
                      TouchEvent(action: action, pointerId: 0, nx: points.zero.nx, ny: points.zero.ny)])
    }

    /// Two-finger double tap: down/up/down/up at the cursor.
    func smartMagnify(at point: CGPoint) {
        guard !suspended else { return }
        flushText()
        let (nx, ny) = normalized(point)
        tap(nx: nx, ny: ny)
        scheduleSecondTap { [weak self] in self?.tap(nx: nx, ny: ny) }
    }

    private func tap(nx: Float, ny: Float) {
        send?(.touch(TouchEvent(action: .down, nx: nx, ny: ny)))
        send?(.touch(TouchEvent(action: .up, nx: nx, ny: ny)))
    }

    // MARK: Keyboard

    func keyDown(_ event: NSEvent) {
        if suspended {
            // Esc is the mode's own key: it leaves, and nothing reaches the
            // phone. Every other key is dropped while the frame is frozen.
            if event.keyCode == Self.keyCodeEscape { onLiveTextEscape?() }
            return
        }
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
                // One Back per press: a held ⌘[ fires keyDown repeats that
                // must not repeat the nav. `[` is not in metaKeyMap, so this
                // is consumed as Back, never also forwarded as a KEY, and the
                // keyUp below has nothing to release.
                guard !event.isARepeat else { return }
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
        guard !suspended else { return }
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
        guard !suspended else {
            pendingText = ""
            return
        }
        let text = pendingText
        pendingText = ""
        send?(.text(text))
    }

    /// The mode was just entered. A pending text batch and a queued hover move
    /// are forgotten; what the phone is already holding (a touch, a gesture's
    /// fingers, a hover) is cancelled, or Android would keep a finger down
    /// under the frozen frame.
    func dropPendingInput() {
        if let touch = mouseTouch {
            send?(.touch(TouchEvent(action: .cancel, nx: touch.nx, ny: touch.ny)))
            mouseTouch = nil
        }
        sendTrackpad(gestures.cancel())
        if pointerGesture != nil { finishGesture(cancelled: true) }
        if hoverActive { sendHover(.exit, nx: hoverLastPoint.nx, ny: hoverLastPoint.ny) }
        textFlush?.cancel()
        textFlush = nil
        pendingText = ""
        hoverPending = nil
        hoverMoveScheduled = false
        hoverGeneration += 1
        hoverActive = false
        gestures = TrackpadGestures()
        pointerGesture = nil
        gestureComponents = []
        pendingGestureMove = nil
        gestureMoveScheduled = false
        if !livePointers.isEmpty {
            livePointers.removeAll()
            touchPointsChanged?([])
        }
    }

    private func appendText(_ text: String) {
        pendingText += text
        guard textFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushText() }
        textFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.textBatchInterval, execute: work)
    }
}
