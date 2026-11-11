// The "Show phone files in Finder" controller (FilesDomainController.swift),
// with a fake domain manager: no NSFileProviderManager and no File Provider
// anywhere in these tests.

import Foundation
import XCTest
@testable import Contigua

@MainActor
private final class FakeDomainManager: FilesDomainManaging {
    var info: FilesDomainInfo?
    var addError: Error?
    var signalError: Error?
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

    func signalWorkingSet(identifier: String, completion: @escaping (Error?) -> Void) {
        signals.append(identifier)
        completion(signalError)
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
        // These tests model the current build: its bundle carries the extension
        // (the test runner's does not).
        RememberedPhones(profile: profile).removeAll()
        profile.defaults.removeObject(forKey: "phoneNicknames")
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
            openSettings: { [unowned self] in self.openedSettings += 1 },
            supported: true)
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

    /// The extension reaches the app through a socket in the App Group
    /// container, and the socket dies with the process. A relaunch finds the
    /// domain still in place, so `start()` must start the bridge for an
    /// existing domain too: v103 returned before that and Finder showed
    /// "Your device couldn't connect to the server".
    func testARelaunchWithTheDomainInPlaceStartsTheBridge() {
        FilesDomainSetting.write(true, in: profile.defaults)
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        rebuild() // the relaunch: a fresh controller over the same domain
        controller.start()
        XCTAssertEqual(["/tmp/pd-files-test.sock"], started,
                       "an existing domain must still bring the bridge up")
        XCTAssertEqual(.on, controller.state)
        XCTAssertTrue(manager.adds.isEmpty, "the domain is not added again")
    }

    /// A phone-side change signals the working set — the only container a
    /// replicated extension may signal (design "S5 round 3") — and the answer's
    /// error is kept, not discarded.
    func testAPhoneSideChangeSignalsTheWorkingSet() {
        controller.setEnabled(true)
        manager.info?.userEnabled = true
        controller.signalWorkingSet()
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.signals)
        manager.signalError = NSError(domain: "com.apple.FileProvider", code: -2011)
        controller.signalWorkingSet()
        XCTAssertEqual(2, manager.signals.count)
    }

    func testASignalWithTheSettingOffDoesNothing() {
        controller.signalWorkingSet()
        XCTAssertTrue(manager.signals.isEmpty)
    }

    /// The VM hook (`--files-domain add`) adopts a domain without the stored
    /// setting: its phone-side changes must still signal the working set, or
    /// the mount never moves with no extension running (round 3's first VM
    /// run).
    func testAnAdoptedDomainSignalsWithTheSettingOff() {
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        controller.adopt()
        controller.signalWorkingSet()
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.signals)
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
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        rebuild()
        controller.start()
        XCTAssertEqual(.on, controller.state)
        XCTAssertTrue(manager.adds.isEmpty)
    }

    func testAnOldStoredMapFormatDoesNotReplaceTheDomain() {
        // The old format key is ignored: only the current shape is read, so an
        // existing domain is adopted as it is.
        FilesDomainSetting.write(true, in: profile.defaults)
        profile.defaults.set(2, forKey: "files.idsFormat")
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        rebuild()
        controller.start()
        XCTAssertTrue(manager.removes.isEmpty)
        XCTAssertEqual(.on, controller.state)
        XCTAssertTrue(manager.adds.isEmpty)
    }

    func testAnExistingDisabledDomainAsksForTheSwitch() {
        FilesDomainSetting.write(true, in: profile.defaults)
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
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

    func testAnAdoptedDomainFollowsTheSessionWithTheSettingOff() {
        // The VM hook (`--files-domain add`) adds the domain itself; its app
        // process is the bridge, so session transitions must still reach it.
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        controller.adopt()
        controller.sessionReady(true)
        XCTAssertEqual(1, manager.reconnects.count)
        XCTAssertEqual(1, manager.signals.count)
        controller.sessionReady(false)
        XCTAssertEqual(1, manager.disconnects.count)
        XCTAssertEqual(["Phone not connected"], manager.disconnects.map(\.reason))
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
            startBridge: { _ in "ok" }, stopBridge: {}, openSettings: {},
            supported: true)
        // The test bundle has no PDFilesGroup: there is no socket to start.
        bare.setEnabled(true)
        XCTAssertEqual(.failed, bare.state)
    }

    // MARK: Bundle without the Files extension ("Fixes 10-20")

    func testABundleWithoutTheExtensionNeverAddsADomain() {
        FilesDomainSetting.write(true, in: profile.defaults)
        let bare = FilesDomainController(
            profile: profile, manager: manager, socketPath: "/tmp/pd-files-test.sock",
            startBridge: { [unowned self] path in
                self.started.append(path)
                return "ok"
            }, stopBridge: {}, openSettings: {}, supported: false)
        bare.start()
        XCTAssertFalse(bare.supported)
        XCTAssertFalse(bare.enabled)
        XCTAssertEqual(.off, bare.state)
        XCTAssertTrue(manager.adds.isEmpty)
        XCTAssertTrue(started.isEmpty)
        // Turning the (disabled) switch on by hand still adds nothing.
        bare.setEnabled(true)
        XCTAssertEqual(.off, bare.state)
        XCTAssertFalse(bare.enabled)
        XCTAssertTrue(manager.adds.isEmpty)
        XCTAssertTrue(started.isEmpty)
    }

    // MARK: The Finder location's name ("Fixes 10-20")

    func testTheLocationNameCarriesThePhoneName() {
        XCTAssertEqual("Contigua", FilesDomain.locationName(phoneName: ""))
        XCTAssertEqual("Contigua", FilesDomain.locationName(phoneName: "  "))
        XCTAssertEqual("Contigua (Pixel 9)", FilesDomain.locationName(phoneName: "Pixel 9"))
        XCTAssertEqual("Contigua (Nicky)", FilesDomain.locationName(phoneName: " Nicky "))
        XCTAssertEqual("Contigua", FilesDomain.displayName(profile: profile))
        let phones = RememberedPhones(profile: profile)
        phones.remember(PhoneRef(id: "p1", name: "Pixel 9", model: "pixel"))
        XCTAssertEqual("Contigua (Pixel 9)", FilesDomain.displayName(profile: profile))
        PhoneNicknames.write("Nicky", for: "p1", to: profile.defaults)
        XCTAssertEqual("Contigua (Nicky)", FilesDomain.displayName(profile: profile))
    }

    func testARenameUpdatesTheExistingDomainInPlace() {
        FilesDomainSetting.write(true, in: profile.defaults)
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        RememberedPhones(profile: profile).remember(PhoneRef(id: "p1", name: "Pixel 9", model: ""))
        rebuild()
        controller.start()
        // Same identifier, new display name: macOS updates the domain rather
        // than removing it (which would delete its folder and cache).
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.adds.map(\.identifier))
        XCTAssertEqual(["Contigua (Pixel 9)"], manager.adds.map(\.displayName))
        XCTAssertTrue(manager.removes.isEmpty)
    }

    func testTheNameIsNotReAddedWhenItAlreadyMatches() {
        FilesDomainSetting.write(true, in: profile.defaults)
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        rebuild()
        controller.start()
        XCTAssertTrue(manager.adds.isEmpty)
    }

    func testTheNameArrivingAfterTheAddUpdatesTheDomain() {
        // The e2e hook adds the domain at launch, before the phone is known;
        // the session then remembers the phone and its name.
        manager.info = FilesDomainInfo(identifier: FilesDomain.identifier(profile: profile),
                                       displayName: "Contigua", isDisconnected: false,
                                       userEnabled: true)
        controller.adopt()
        RememberedPhones(profile: profile).remember(PhoneRef(id: "p1", name: "FakePhone", model: ""))
        controller.sessionReady(true)
        XCTAssertEqual(["Contigua (FakePhone)"], manager.adds.map(\.displayName))
        XCTAssertEqual([FilesDomain.identifier(profile: profile)], manager.reconnects)
    }
}