// The second shim's menu (WIN-26, ISS-4): one `DockApps` can own several shims
// of one phone at once, and each of them must get its app's window menu.
//
// A shim that starts listening after the bind has already happened misses the
// bind's one `menu` post. The shim's `ready` retry exists for exactly that
// launch race (DOCK-17), and a bound pid's answer must carry the menu with the
// `opened`: otherwise the shim stays alive with an empty Dock menu until some
// later window-set change happens to refresh it. The VM run (round 3) showed
// it as a second shim that bound but never wrote its menu dump.
//
// The test's shims are observers of `DockMessage.menu`, the same message the
// real shim renders, and they write the dump the real shim writes.

import AppKit
import XCTest
@testable import PocketDeck

final class DockShimMenuTests: XCTestCase {
    private var folder: URL!
    private var apps: DockApps!
    private let profile = Profile(name: "e2e")!
    private var shims: [FakeShim] = []
    private var sleepers: [Process] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-menu-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        apps = DockApps(folder: folder, profile: profile)
    }

    override func tearDownWithError() throws {
        DistributedNotificationCenter.default().removeObserver(apps as Any)
        for shim in shims { shim.stop() }
        shims = []
        for sleeper in sleepers {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        sleepers = []
        apps = nil
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The test's shim

    /// What the real shim does with a menu: keep the rows and write its dump.
    /// It can start listening late, after the host's bind, like a slow launch.
    private final class FakeShim {
        let pid: Int
        let pkg: String
        private let center = DistributedNotificationCenter.default()
        private let dump: URL
        private var observers: [NSObjectProtocol] = []
        private(set) var rows: [[String: Any]] = []
        private(set) var opened = false
        let menuArrived = XCTestExpectation(description: "the shim's menu")
        let openedArrived = XCTestExpectation(description: "the shim's opened")

        init(pid: Int, pkg: String, dump: URL) {
            self.pid = pid
            self.pkg = pkg
            self.dump = dump
        }

        /// Register the observers. A shim built by an automatic launch that
        /// was still starting when the host bound it starts here.
        func listen(expectMenu: Bool = true) {
            let menuObserver = center.addObserver(forName: DockMessage.menu, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      (note.userInfo?[DockMessage.pidKey] as? Int) == self.pid,
                      let messages = note.userInfo?[DockMessage.rowsKey] as? [[String: Any]] else { return }
                self.rows = messages
                let data = try? JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])
                try? data?.write(to: self.dump)
                if expectMenu { self.menuArrived.fulfill() }
            }
            let openedObserver = center.addObserver(forName: DockMessage.opened, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      (note.userInfo?[DockMessage.pidKey] as? Int) == self.pid else { return }
                self.opened = true
                self.openedArrived.fulfill()
            }
            observers = [menuObserver, openedObserver]
        }

        func stop() {
            for observer in observers { center.removeObserver(observer) }
            observers = []
        }

        /// The automatic launch's retry: the shim says it is listening.
        func postReady(deviceId: String, token: String, profile: String) {
            center.postNotificationName(DockMessage.ready, object: profile,
                                        userInfo: [DockMessage.deviceIdKey: deviceId,
                                                   DockMessage.pkgKey: pkg,
                                                   DockMessage.pidKey: pid,
                                                   DockMessage.tokenKey: token],
                                        deliverImmediately: true)
        }
    }

    // MARK: Fixtures

    private let deviceId = "a1b2c3d4e5f60718"

    private func binary() throws -> URL {
        let url = folder.appendingPathComponent("shim-binary")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func bundle(pkg: String, label: String) throws -> DockShimRecord {
        let spec = DockShimSpec(deviceId: deviceId, pkg: pkg, label: label, phoneName: "FakePhone",
                                profile: profile, hostPath: "/tmp/PocketDeck.app")
        _ = try DockShimBuilder.build(spec, in: folder, shimBinary: try binary(), icon: nil)
        return try XCTUnwrap(apps.records().first { $0.pkg == pkg })
    }

    /// A live pid for a process the test owns: `bind` watches the pid and a
    /// dead one would count as the shim quitting at once.
    private func livePid() throws -> Int {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        sleepers.append(sleeper)
        return Int(sleeper.processIdentifier)
    }

    private func rows(for pkg: String) -> [AppWindowMenuRow] {
        let app = pkg == "com.android.chrome" ? "Chrome" : "Settings"
        return [
            AppWindowMenuRow(title: "New \(app) Window", action: .newWindow, key: "n"),
            AppWindowMenuRow(title: "\(app) — Docs", action: .raise(stream: 1), checked: true),
        ]
    }

    // MARK: The second shim

    /// Two shims of one phone in one `DockApps`: the first is listening before
    /// its bind; the second starts listening after it. Both must receive their
    /// app's menu and write it down. The second one's only chance is the answer
    /// to its `ready`, because it missed the bind's own post.
    func testASecondShimThatStartsListeningLateStillGetsItsMenu() throws {
        let settings = try bundle(pkg: "com.android.settings", label: "Settings")
        let chrome = try bundle(pkg: "com.android.chrome", label: "Chrome")
        apps.windowMenu = { [unowned self] _, pkg in self.rows(for: pkg) }
        apps.start()

        let firstDump = folder.appendingPathComponent("dockmenu-com.android.settings.json")
        let first = FakeShim(pid: try livePid(), pkg: settings.pkg, dump: firstDump)
        first.listen()
        shims.append(first)
        apps.bind(pid: first.pid, stream: 1, pkg: settings.pkg, deviceId: deviceId)
        wait(for: [first.menuArrived], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstDump.path),
                      "the first shim writes its dump")

        // The second shim's bind lands before it listens: the host's bind-time
        // post has no observer, exactly the slow second launch in the VM.
        let secondDump = folder.appendingPathComponent("dockmenu-com.android.chrome.json")
        let second = FakeShim(pid: try livePid(), pkg: chrome.pkg, dump: secondDump)
        shims.append(second)
        apps.bind(pid: second.pid, stream: 2, pkg: chrome.pkg, deviceId: deviceId)
        XCTAssertTrue(apps.boundStreams.contains(2))

        // It now starts listening and says so, the way DockShimMachine retries.
        second.listen()
        second.postReady(deviceId: deviceId, token: chrome.token, profile: profile.name)

        wait(for: [second.openedArrived, second.menuArrived], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondDump.path),
                      "the second shim writes the same dump the first one did")
        let dumped = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: secondDump)) as? [[String: Any]])
        XCTAssertEqual(dumped.compactMap { $0["title"] as? String },
                       ["New Chrome Window", "Chrome — Docs"],
                       "the answer carries the app's current menu, not an empty one")
    }
}
