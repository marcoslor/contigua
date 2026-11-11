// Shared fixture for the several-windows-of-one-app tests (WIN-24…WIN-36):
// one WindowManager with one "phone" and the apps a check needs, and helpers
// that read what reached the phone (Session's test hook) and where the windows
// are.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class MultiWindowFixture {
    let manager: WindowManager
    let session: Session
    private let defaultsName: String
    private let defaults: UserDefaults

    static let chrome = AppInfo(json: ["pkg": "com.android.chrome", "label": "Chrome",
                                       "activity": "com.android.chrome/com.android.chrome.Main",
                                       "multi": true])!
    static let settings = AppInfo(json: ["pkg": "com.android.settings", "label": "Settings"])!
    static let deviceId = "phone-1"

    init(apps: [AppInfo] = [MultiWindowFixture.chrome, MultiWindowFixture.settings],
         phoneId: String = MultiWindowFixture.deviceId, phoneName: String = "Pixel 9") {
        defaultsName = "app.contigua.tests.multiwin.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1),
                          knownDeviceId: nil, clientId: "test-client")
        manager = WindowManager(session: session, defaults: defaults)
        manager.appsByPkg = Dictionary(apps.map { ($0.pkg, $0) }, uniquingKeysWith: { first, _ in first })
        manager.phone = PhoneInfo(device: ["id": phoneId, "name": phoneName, "model": "Pixel 9",
                                           "sdk": 36, "screen": ["w": 1080, "h": 2340, "dpi": 420],
                                           "locked": true])
        manager.setPhoneName(phoneName)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    /// An app window in the state a check needs; `label` is the task's label
    /// the phone reported.
    @discardableResult
    func open(_ app: AppInfo = chrome, taskLabel: String? = nil,
              firstFrame: Bool = true) -> AppWindowController {
        let window = manager.openOrRaise(pkg: app.pkg)
        if let taskLabel { manager.setTaskLabel(taskLabel, stream: window.stream) }
        if firstFrame { window.noteFirstFrame() }
        return window
    }

    /// A second (or later) window of the app, as the New item opens one.
    @discardableResult
    func add(_ app: AppInfo = chrome, taskLabel: String? = nil,
             firstFrame: Bool = true) -> AppWindowController? {
        guard let window = manager.openAdditional(pkg: app.pkg) else { return nil }
        if let taskLabel { manager.setTaskLabel(taskLabel, stream: window.stream) }
        if firstFrame { window.noteFirstFrame() }
        return window
    }

    /// `window.open` messages the Mac asked the phone for, as dictionaries.
    var openRequests: [[String: Any]] { session.sent("window.open") }
    var closeRequests: [[String: Any]] { session.sent("window.close") }

    /// Every window closes as the person's ⌘W does, so no window outlives a
    /// test.
    func closeAll() {
        for stream in manager.openStreams {
            manager.controller(for: stream)?.window?.close()
        }
    }
}
