// The "Show phone files in Finder" controller (FilesDomainController.swift),
// with a fake domain manager: no NSFileProviderManager and no File Provider
// anywhere in these tests.

import Foundation
import XCTest
@testable import PocketDeck

@MainActor
private final class FakeDomainManager: FilesDomainManaging {
    var info: FilesDomainInfo?
    var addError: Error?
    var removeError: Error?
    private(set) var adds: [(identifier: String, displayName: String)] = []
    private(set) var removes: [String] = []
    private(set) var reconnects: [String] = []
    private(set) var disconnects: [(id: String, reason: String)] = []
    private(set) var signals: [String] = []

    func domain(identifier: String) -> FilesDomainInfo? {
        guard let info, info.identifier == identifier else { return nil }
        return info
    }

    func add(identifier: String, displayName: String, completion: @escaping (Error?) -> Void) {
        adds.append((identifier, displayName))
        if addError == nil {
            info = FilesDomainInfo(identifier: identifier, displayName: displayName,
                                   isDisconnected: false, userEnabled: false)
        }
        completion(addError)
    }

    func remove(identifier: String, completion: @escaping (Error?) -> Void) {
        removes.append(identifier)
        if removeError == nil { info = nil }
        completion(removeError)
    }

    func reconnect(identifier: String, completion: @escaping (Error?) -> Void) {
        reconnects.append(identifier)
        completion(nil)
    }

    func disconnect(identifier: String, reason: String,
                    completion: @escaping (Error?) -> Void) {
        disconnects.append((identifier, reason))
        completion(nil)
    }

    func signalEnumerator(identifier: String, completion: @escaping (Error?) -> Void) {
        signals.append(identifier)
        completion(nil)
    }
}

@MainActor
final class FilesDomainControllerTests: XCTestCase {
    private var profile: Profile!
    private var manager: FakeDomainManager!
    private var started: [String] = []
    private var stopped = 0
    private var openedSettings = 0
    private var controller: FilesDomainController!

    override func setUp() async throws {
        profile = Profile(name: "ftest")!
        FilesDomainSetting.write(false, in: profile.defaults)
        manager = FakeDomainManager()
        started = []
        stopped = 0
        openedSettings = 0
        rebuild()
    }

    /// A fresh controller over the same fakes: the setting is read at init, as
    /// it is at app launch.
    private func rebuild() {
        controller = FilesDomainController(
            profile: profile,
            manager: manager,
            socketPath: "/tmp/pd-files-test.sock",
            startBridge: { [unowned self] path in
                self.started.append(path)
                return "ok"
            },
            stopBridge: { [unowned self] in self.stopped += 1 },
            openSettings: { [unowned self] in self.openedSettings += 1 })
    }

    override func tearDown() async throws {
        FilesDomainSetting.write(false, in: profile.defaults)
    }

    func testTheSettingOffMeansNoDomain() {
        controller.start()
        XCTAssertEqual(.off, controller.state)
        XCTAssertFalse(controller.enabled)
        XCTAssertTrue(manager.adds.isEmpty)
        XCTAssertTrue(started.isEmpty)
    }

    func testEnablingAddsOnceAndShowsTheSwitchPrompt() {
        controller.setEnabled(true)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(1, manager.adds.count)
        XCTAssertEqual(FilesDomain.identifier(profile: profile), manager.adds.first?.identifier)
        XCTAssertEqual(["/tmp/pd-files-test.sock"], started)
        // A fresh domain starts user-disabled.
        XCTAssertEqual(.needsSwitch, controller.state)
        XCTAssertTrue(controller.needsSwitch)
        // Enabling again changes nothing (the UI can re-send the same value).
        controller.setEnabled(true)
        XCTAssertEqual(1, manager.adds.count)
        XCTAssertEqual(1, started.count)
    }

    func testTheSwitchTurningOnMovesTheStateToOn() {
        controller.setEnabled(true)
        manager.info?.userEnabled = true
        controller.refresh()
        XCTAssertEqual(.on, controller.state)
        XCTAssertFalse(controller.needsSwitch)
        controller.refresh()
        XCTAssertEqual(.on, controller.state)
    }

    func testSessionTransitionsReconnectAndDisconnectOnce() {
        controller.setEnabled(true)
        manager.info?.userEnabled = true
        controller.refresh()
        controller.sessionReady(true)
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.reconnects)
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.signals)
        controller.sessionReady(true)
        XCTAssertEqual(1, manager.reconnects.count)
        XCTAssertEqual(1, manager.signals.count)
        controller.sessionReady(false)
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.disconnects.map(\.id))
        XCTAssertEqual(["Phone not connected"], manager.disconnects.map(\.reason))
        controller.sessionReady(false)
        XCTAssertEqual(1, manager.disconnects.count)
    }

    func testASessionUpBeforeTheDomainIsAddedReconnectsAfterTheAdd() {
        controller.sessionReady(true)
        controller.setEnabled(true)
        XCTAssertEqual(1, manager.reconnects.count)
        XCTAssertEqual(1, manager.signals.count)
    }

    func testAnExistingEnabledDomainAtLaunchAddsNothing() {
        FilesDomainSetting.write(true, in: profile.defaults)
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "PocketDeck", isDisconnected: false,
                                       userEnabled: true)
        rebuild()
        controller.start()
        XCTAssertEqual(.on, controller.state)
        XCTAssertTrue(manager.adds.isEmpty)
    }

    func testAnExistingDisabledDomainAsksForTheSwitch() {
        FilesDomainSetting.write(true, in: profile.defaults)
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "PocketDeck", isDisconnected: false,
                                       userEnabled: false)
        rebuild()
        controller.start()
        XCTAssertEqual(.needsSwitch, controller.state)
        XCTAssertTrue(manager.adds.isEmpty)
    }

    func testTurningOffRemovesTheDomainAndStopsTheBridge() {
        controller.setEnabled(true)
        manager.info?.userEnabled = true
        controller.refresh()
        controller.setEnabled(false)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(.off, controller.state)
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.removes)
        XCTAssertEqual(1, stopped)
        // Off again: no second remove.
        controller.setEnabled(false)
        XCTAssertEqual(1, manager.removes.count)
    }

    func testThePromptButtonOpensSystemSettings() {
        controller.setEnabled(true)
        XCTAssertEqual(.needsSwitch, controller.state)
        controller.openSystemSettings()
        XCTAssertEqual(1, openedSettings)
    }

    func testAFailedAddIsReported() {
        manager.addError = NSError(domain: "test", code: 1)
        controller.setEnabled(true)
        XCTAssertEqual(.failed, controller.state)
        XCTAssertTrue(controller.enabled)
    }

    func testNoBridgeWithoutAnAppGroup() {
        let bare = FilesDomainController(
            profile: profile, manager: manager, socketPath: nil,
            startBridge: { _ in "ok" }, stopBridge: {}, openSettings: {})
        // The test bundle has no PDFilesGroup: there is no socket to start.
        bare.setEnabled(true)
        XCTAssertEqual(.failed, bare.state)
    }
}
