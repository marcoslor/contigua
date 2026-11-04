// What the app's menu commands are built from, and when SwiftUI may rebuild
// them.
//
// `AppCommands` is SwiftUI `.commands`: SwiftUI builds its NSMenu items when the
// commands body is evaluated, and it evaluates the body whenever any observed
// value the body reads changes. The body used to read the whole connection
// state (a battery report, a stall flip, a Now Playing update, an occlusion
// pause), so those rebuilt the bar while a menu was open and the person's
// submenu kept closing under the pointer (the 10-27 report).
//
// The body now reads one value: this model's `snapshot`, a small Equatable
// summary of the values the menu actually shows (titles, marks, enablement).
// The model recomputes it from the controller and the key window's state, and
// publishes it only when it really differs — and never while a menu is
// tracking, where it waits for the menu to close (MenuSnapshotGate). The marks
// in an open menu are still written onto the items by MenuMarks.

import AppKit
import Observation

// MARK: - The snapshot

/// Everything the app's menu items read, as one value.
struct MenuSnapshot: Equatable {
    /// The Phone menu's items: the panel's own mapping decides enablement, so
    /// the two menus cannot disagree (docs/specs/menus.md MENU-5).
    struct Phone: Equatable {
        var mirrorEnabled = false
        var continueEnabled = false
        var dndEnabled = false
        var dndOn = false
        var ringEnabled = false
        var ringing = false
        var ringTitle = "Ring Phone"
        var installEnabled = false
        var installTitle = "Install APK…"

        init() {}

        /// Only the values a Phone item shows. Battery, media, live rows and
        /// the agent count are not among them, so they never rebuild the bar.
        init(_ state: PhoneControlsState) {
            mirrorEnabled = PhonePanelItem.phoneScreen.isEnabled(in: state)
            continueEnabled = PhonePanelItem.continueOnMac.isEnabled(in: state)
            dndEnabled = PhonePanelItem.dnd.isEnabled(in: state)
            dndOn = state.dnd?.isOn ?? false
            ringEnabled = PhonePanelItem.ring.isEnabled(in: state)
            ringing = state.ringing
            ringTitle = state.ringTitle
            installEnabled = PhonePanelItem.installApk.isEnabled(in: state)
            installTitle = state.installTitle
        }
    }

    var hasStream = false
    var style: WindowStyle = .standard
    var fullScreen = false
    var fullScreenAllowed = true
    var showTouches = false
    var liveText = false
    var frozen = false
    var phoneWindow = false
    var phoneOffline = false
    var panelOff = false
    var revealDelay: RevealDelay = .short
    var densityPackage: String?
    var densityOverride: Double?
    var settingsDensity = 1.0
    /// File ▸ New <App> Window: the key app's title, enablement and the one
    /// sentence when it cannot act (MENU-2, WIN-25, WIN-27, WIN-32, WIN-34).
    var newWindow = NewWindowItem(title: "New Window", enabled: false, help: nil)
    /// Window ▸ Next Window ⌘`: enabled only while the key app has two or more
    /// windows open (WIN-29, WIN-30).
    var nextWindowEnabled = false
    var phone = Phone()

    init() {}

    /// The values the View, Phone, Navigate and Window items show. Reading them
    /// is what registers this model for the changes it must react to; nothing
    /// else may be read here, or the bar goes back to rebuilding on it.
    init(stream: StreamMenuState, phone: Phone) {
        hasStream = stream.hasStream
        style = stream.style
        fullScreen = stream.fullScreen
        fullScreenAllowed = stream.fullScreenAllowed
        showTouches = stream.showTouches
        liveText = stream.liveText
        frozen = stream.frozen
        phoneWindow = stream.phoneWindow
        phoneOffline = stream.phoneOffline
        panelOff = stream.panelOff
        revealDelay = stream.revealDelay
        densityPackage = stream.densityPackage
        densityOverride = stream.densityOverride
        settingsDensity = stream.settingsDensity
        self.phone = phone
    }
}

// MARK: - When a new snapshot may reach the commands

/// The rule that keeps SwiftUI from rebuilding menu items while a menu tracks:
/// a change waits for the menu to close, and only the latest one is kept.
struct MenuSnapshotGate {
    private(set) var applied: MenuSnapshot?
    private(set) var deferred: MenuSnapshot?
    private(set) var tracking = false

    /// The value the commands are about to be built from, with no change to
    /// publish: the launch state, so the first build is the only one.
    mutating func begin(from snapshot: MenuSnapshot) {
        applied = snapshot
        deferred = nil
    }

    /// A state change arrived. Returns the snapshot to publish now, if any.
    mutating func update(_ snapshot: MenuSnapshot) -> MenuSnapshot? {
        guard snapshot != applied else {
            // Back to what the commands hold: a value that was waiting is
            // pointless now, and must not land when the menu closes.
            deferred = nil
            return nil
        }
        guard !tracking else {
            deferred = snapshot
            return nil
        }
        applied = snapshot
        return snapshot
    }

    /// A menu began or finished tracking. Ending publishes the change that
    /// waited, if it still differs from what the commands hold.
    mutating func tracking(_ began: Bool) -> MenuSnapshot? {
        tracking = began
        guard !began, let waiting = deferred else { return nil }
        deferred = nil
        guard waiting != applied else { return nil }
        applied = waiting
        return waiting
    }
}

// MARK: - The model

@Observable
@MainActor
final class MenuBarModel {
    static let shared = MenuBarModel()

    /// How often the model reads the state the menu shows. A poll, not an
    /// observation callback: a change is picked up at a predictable moment
    /// (never in the middle of a menu dump or a menu's own validation), and the
    /// comparison below is a handful of reads.
    static let interval: TimeInterval = 0.25

    /// The state the commands were last built from.
    private(set) var snapshot = MenuSnapshot()

    @ObservationIgnored private var gate = MenuSnapshotGate()
    @ObservationIgnored private var controller: ConnectionController?
    @ObservationIgnored private var timer: Timer?

    init() {}

    /// Starts following the controller and the key window's menu state. Called
    /// once at launch, from `applicationDidFinishLaunching`.
    func start(controller: ConnectionController) {
        self.controller = controller
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The launch state is what the commands will build from: assigning it
        // now is not a change, so the bar is built once (a rebuild here makes
        // AppKit show its own full-screen item beside the app's).
        let start = currentSnapshot(controller)
        gate.begin(from: start)
        snapshot = start
    }

    /// Recomputes and publishes if the menu's values changed.
    func refresh() {
        guard let published = gate.update(currentSnapshot()) else { return }
        snapshot = published
    }

    private func currentSnapshot(_ controller: ConnectionController? = nil) -> MenuSnapshot {
        let controller = controller ?? self.controller ?? AppEnvironment.shared.controller
        var snapshot = MenuSnapshot(stream: StreamMenuState.shared,
                                    phone: MenuSnapshot.Phone(PhoneControlsState(controller: controller)))
        // The two window items read the running app's own window set, which
        // SwiftUI's commands cannot see (MENU-2, MENU-7).
        let windows = controller.windows
        snapshot.newWindow = windows.keyNewWindowItem
        snapshot.nextWindowEnabled = windows.canCycleWindows
        return snapshot
    }

    // MARK: Tracking

    func trackingBegan() {
        if let published = gate.tracking(true) {
            snapshot = published
        }
    }

    func trackingEnded() {
        if let published = gate.tracking(false) {
            snapshot = published
        }
    }
}

// MARK: - Whether a menu is open

/// Whether any of the app's menus is tracking. A menu is transient: it is not
/// the reason to stop encoding a stream, and it must not rebuild its own items
/// while it is up.
@MainActor
enum MenuTracking {
    private(set) static var isTracking = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { begin() }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,
                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { end() }
        })
    }

    private static func begin() {
        isTracking = true
        MenuBarModel.shared.trackingBegan()
    }

    private static func end() {
        isTracking = false
        MenuBarModel.shared.trackingEnded()
        // The menu may have been covering a stream: now that it is gone, the
        // window's own occlusion decides again.
        AppEnvironment.shared.controller.windows.reevaluatePause()
    }
}

/// How many times SwiftUI evaluated the app's commands. The e2e `menus` check
/// reads it either side of a menu it held open: a rebuild while a menu tracks
/// is what closes the person's submenu.
@MainActor
enum Menus {
    private(set) static var builds = 0

    static func noteBuild() { builds += 1 }
}
