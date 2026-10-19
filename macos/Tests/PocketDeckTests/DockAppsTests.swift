import AppKit
import XCTest
@testable import PocketDeck

final class DockAppsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dock-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func spec(deviceId: String = "a1b2c3d4e5f60718", pkg: String = "com.whatsapp", label: String = "WhatsApp",
                      phoneName: String = "Pixel", profile: Profile = Profile(name: "e2e")!) -> DockShimSpec {
        DockShimSpec(deviceId: deviceId, pkg: pkg, label: label, phoneName: phoneName, profile: profile,
                     hostPath: "/tmp/PocketDeck.app")
    }

    private func png(size: Int = 96) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func binary() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("shim-binary")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    // MARK: Identity

    func testBundleIdIsDerivedFromProfilePhoneAndPackage() {
        XCTAssertEqual(spec().bundleIdentifier, "dev.pocketdeck.dock.e2e.a1b2c3d4e5f60718.com-whatsapp")
        XCTAssertEqual(spec(profile: .default).bundleIdentifier, "dev.pocketdeck.dock.a1b2c3d4e5f60718.com-whatsapp")
    }

    func testBundleIdDropsUnsafeCharacters() {
        let id = spec(deviceId: "../x y", pkg: "com.ex_ample/../é").bundleIdentifier
        XCTAssertEqual(id, "dev.pocketdeck.dock.e2e.---x-y.com-ex-ample-----")
        XCTAssertTrue(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        XCTAssertEqual(DockShimSpec.idPart(""), "x")
    }

    func testSamePackageOnTwoPhonesGetsTwoIdentities() {
        XCTAssertNotEqual(spec(deviceId: "aaaa").bundleIdentifier, spec(deviceId: "bbbb").bundleIdentifier)
        XCTAssertNotEqual(spec(phoneName: "Pixel").fileName, spec(phoneName: "Galaxy").fileName)
    }

    func testNameAndFileName() {
        XCTAssertEqual(spec().displayName, "WhatsApp (Pixel)")
        XCTAssertEqual(spec().fileName, "WhatsApp (Pixel).app")
        XCTAssertEqual(spec(label: "../evil:app", phoneName: "a/b").fileName, "-evil-app (a-b).app")
        XCTAssertEqual(spec(label: ".hidden").fileName, "hidden (Pixel).app")
    }

    func testInfoPlistKeys() {
        let plist = spec(label: "Tom & \"Jerry\" <1>").infoPlist
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "PocketDeckShim")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Tom & \"Jerry\" <1> (Pixel)")
        XCTAssertEqual(plist["PDDeviceId"] as? String, "a1b2c3d4e5f60718")
        XCTAssertEqual(plist["PDPackage"] as? String, "com.whatsapp")
        XCTAssertEqual(plist["PDProfile"] as? String, "e2e")
        XCTAssertEqual(plist["PDHostPath"] as? String, "/tmp/PocketDeck.app")
        XCTAssertEqual(plist["PDPinned"] as? Bool, false, "an automatic shim is not pinned")
        XCTAssertNil(plist["LSUIElement"], "the shim must show in the Dock and ⌘-Tab")
        var manual = spec()
        manual.pinned = true
        XCTAssertEqual(manual.infoPlist["PDPinned"] as? Bool, true)
    }

    func testBackgroundModeShimsAreAgents() {
        var quiet = spec()
        quiet.agent = true
        XCTAssertEqual(quiet.infoPlist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(quiet.infoPlist["CFBundleIdentifier"] as? String, spec().infoPlist["CFBundleIdentifier"] as? String)
    }

    // MARK: Bundle on disk

    func testBuildWritesAReadableBundleWithEscapedNames() throws {
        let label = "Tom & \"Jerry\" <1>"
        var pinned = spec(label: label)
        pinned.pinned = true
        let url = try DockShimBuilder.build(pinned, in: folder, shimBinary: try binary(), iconPNG: png())
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, "dev.pocketdeck.dock.e2e.a1b2c3d4e5f60718.com-whatsapp")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, "\(label) (Pixel)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/PocketDeckShim").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).map(\.pkg), ["com.whatsapp"])
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).map(\.pinned), [true])
        let token = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "PDToken") as? String)
        XCTAssertTrue(DockToken.isWellFormed(token), "the bundle carries a token for the host's checks")
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).map(\.token), [token])
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: .default), [], "another profile's shims are not ours")
    }

    func testBuildWithoutIconStillWorksAndRebuildReplaces() throws {
        let binary = try binary()
        let first = try DockShimBuilder.build(spec(), in: folder, shimBinary: binary, iconPNG: nil)
        let second = try DockShimBuilder.build(spec(), in: folder, shimBinary: binary, iconPNG: png())
        XCTAssertEqual(first, second)
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).count, 1)
    }

    func testIcnsFromPNGHasEveryStandardSize() throws {
        let icns = try XCTUnwrap(DockShimBuilder.icns(fromPNG: png()))
        XCTAssertEqual(Array(icns.prefix(4)), Array("icns".utf8))
        let image = try XCTUnwrap(NSImage(data: icns))
        let widths = Set(image.representations.map(\.pixelsWide))
        XCTAssertTrue(widths.isSuperset(of: [16, 32, 128, 256, 512]), "\(widths.sorted())")
        XCTAssertNil(DockShimBuilder.icns(fromPNG: Data("not a png".utf8)))
    }

    // MARK: Cleanup decisions

    private func record(_ pkg: String, device: String = "d1", name: String, pinned: Bool = false) -> DockShimRecord {
        DockShimRecord(url: URL(fileURLWithPath: "/x/\(pkg)-\(device).app"), deviceId: device, pkg: pkg,
                       profile: "e2e", name: name, pinned: pinned,
                       token: String(repeating: "a", count: 32))
    }

    private func app(_ pkg: String, _ label: String) -> AppInfo {
        AppInfo(json: ["pkg": pkg, "label": label])!
    }

    func testUninstalledAppsAreRemovedRenamedOnesRebuilt() {
        let records = [record("a", name: "A (Pixel)"), record("b", name: "B (Pixel)"),
                       record("c", name: "C (Pixel)"), record("a", device: "d2", name: "A (Other)")]
        let plan = DockCleanup.plan(records: records, deviceId: "d1",
                                    apps: [app("a", "A"), app("c", "Cee")], phoneName: "Pixel")
        XCTAssertEqual(plan, [.remove(records[1].url), .rebuild(records[2], label: "Cee")])
    }

    func testPhoneRenameRebuildsEveryShimOfThatPhone() {
        let records = [record("a", name: "A (Pixel)"), record("b", name: "B (Pixel)")]
        let plan = DockCleanup.plan(records: records, deviceId: "d1", apps: [app("a", "A"), app("b", "B")],
                                    phoneName: "Work phone")
        XCTAssertEqual(plan, [.rebuild(records[0], label: "A"), .rebuild(records[1], label: "B")])
    }

    func testNothingToDoWhenUpToDate() {
        XCTAssertEqual(DockCleanup.plan(records: [record("a", name: "A (Pixel)")], deviceId: "d1",
                                        apps: [app("a", "A")], phoneName: "Pixel"), [])
    }

    func testALegacyShimWithoutTokenIsRebuiltByTheNextRefresh() {
        var legacy = record("a", name: "A (Pixel)")
        legacy.token = ""
        XCTAssertEqual(DockCleanup.plan(records: [legacy], deviceId: "d1",
                                        apps: [app("a", "A")], phoneName: "Pixel"),
                       [.rebuild(legacy, label: "A")])
    }

    // MARK: Message tokens (sec L-8)

    func testTokensAreRandomAndWellFormed() {
        let a = DockToken.make()
        let b = DockToken.make()
        XCTAssertTrue(DockToken.isWellFormed(a), a)
        XCTAssertTrue(DockToken.isWellFormed(b), b)
        XCTAssertNotEqual(a, b)
    }

    func testOnlyTheShimsOwnTokenMatches() {
        let stored = String(repeating: "ab", count: 16)
        XCTAssertTrue(DockToken.matches(message: stored, stored: stored))
        XCTAssertFalse(DockToken.matches(message: String(repeating: "ac", count: 16), stored: stored))
        XCTAssertFalse(DockToken.matches(message: nil, stored: stored))
        XCTAssertFalse(DockToken.matches(message: stored, stored: nil))
        XCTAssertFalse(DockToken.matches(message: "", stored: ""))
        XCTAssertFalse(DockToken.matches(message: "short", stored: "short"))
        XCTAssertFalse(DockToken.matches(message: String(repeating: "AB", count: 16),
                                         stored: String(repeating: "AB", count: 16)),
                       "uppercase is not the format the host writes")
    }

    func testForgetRemovesOnlyThatPhonesShims() {
        let records = [record("a", name: "A (P)"), record("a", device: "d2", name: "A (Q)")]
        XCTAssertEqual(DockCleanup.planForget(records: records, deviceId: "d2"), [.remove(records[1].url)])
    }

    // MARK: The setting's off state (docs/design/dock.md §Lifecycle)

    func testTurningTheSettingOffStopsOnlyUnpinnedShims() {
        let records = [record("a", name: "A (P)"), record("b", name: "B (P)", pinned: true),
                       record("c", device: "d2", name: "C (Q)")]
        XCTAssertEqual(DockQuit.plan(records: records).map(\.pkg), ["a", "c"],
                       "shims added by hand are not stopped by the setting")
    }

    func testLegacyShimsWithoutTheMarkerCountAsPinned() throws {
        // Bundles from before automatic identities: all added by hand, so a
        // missing PDPinned key must not make the setting stop them.
        let url = try DockShimBuilder.build(spec(), in: folder, shimBinary: try binary(), iconPNG: nil)
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: try Data(contentsOf: plistURL),
                                                                        format: nil) as? [String: Any])
        plist.removeValue(forKey: "PDPinned")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        let records = DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!)
        XCTAssertEqual(records.map(\.pinned), [true])
    }

    func testTestProfilesNeverUseApplicationsFolder() {
        let e2e = DockApps.defaultFolder(profile: Profile(name: "e2e")!, override: nil)
        XCTAssertFalse(e2e.path.contains("/Applications/"), e2e.path)
        XCTAssertEqual(DockApps.defaultFolder(profile: .default, override: "/tmp/d").path, "/tmp/d")
        XCTAssertTrue(DockApps.defaultFolder(profile: .default, override: nil).path.hasSuffix("Applications/PocketDeck Apps"))
    }

    // MARK: The automatic decision (docs/design/dock.md §Lifecycle)

    private func decide(settingOn: Bool = true, shimBinary: Bool = true, phoneKnown: Bool = true,
                        shimExists: Bool = false, shimRunning: Bool = false, shimHasIcon: Bool = false,
                        icon: DockFollow.IconState = .cached) -> DockFollow {
        DockFollow.decide(settingOn: settingOn, shimBinary: shimBinary, phoneKnown: phoneKnown,
                          shimExists: shimExists, shimRunning: shimRunning, shimHasIcon: shimHasIcon, icon: icon)
    }

    func testSettingOffSkipsEverything() {
        XCTAssertEqual(decide(settingOn: false, shimExists: false, icon: .cached), .skip)
        XCTAssertEqual(decide(settingOn: false, shimExists: true, icon: .cached), .skip)
        XCTAssertEqual(decide(settingOn: false, shimExists: true, icon: .unknown), .skip)
    }

    func testNothingToActWithSkipsEvenWhenOn() {
        XCTAssertEqual(decide(shimBinary: false), .skip, "no shim executable in the build")
        XCTAssertEqual(decide(phoneKnown: false), .skip, "no phone: no identity to name")
    }

    func testAMissingShimWaitsForTheIcon() {
        XCTAssertEqual(decide(shimExists: false, icon: .cached), .createAndLaunch)
        XCTAssertEqual(decide(shimExists: false, icon: .reportedMissing), .createAndLaunch,
                       "the phone said there is no icon: a generic tile beats waiting forever")
        XCTAssertEqual(decide(shimExists: false, icon: .unknown), .wait)
    }

    func testAnExistingIdleShimRelaunchesWhenItsIconIsRight() {
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: true, icon: .cached), .launchExisting)
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: false, icon: .cached), .createAndLaunch,
                       "the bundle was built without an icon and there is one now: rebuild")
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: false, icon: .reportedMissing), .launchExisting)
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: false, icon: .unknown), .wait)
    }

    func testARunningIdentityIsNotDoubled() {
        XCTAssertEqual(decide(shimExists: true, shimRunning: true, shimHasIcon: true, icon: .cached), .skip)
    }

    // MARK: Bindings

    func testAShimExitClosesItsWindowOnceWhicheverPathSeesIt() throws {
        let apps = DockApps(folder: folder, profile: Profile(name: "e2e")!)
        var closed: [UInt32] = []
        let gone = expectation(description: "the exit watch closes the window")
        apps.onShimQuit = { stream in closed.append(stream); gone.fulfill() }
        let shim = Process()
        shim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shim.arguments = ["0.3"]
        try shim.run()
        let pid = Int(shim.processIdentifier)
        apps.bind(pid: pid, stream: 4, pkg: "com.whatsapp")
        wait(for: [gone], timeout: 5)
        // NSWorkspace (or the shim's quit message) arriving too is harmless.
        apps.shimExited(pid)
        apps.shimExited(pid)
        XCTAssertEqual(closed, [4])
        XCTAssertNil(apps.stream(forPid: pid))
    }

    func testAShimAlreadyGoneWhenBoundClosesItsWindow() throws {
        let apps = DockApps(folder: folder, profile: Profile(name: "e2e")!)
        var closed: [UInt32] = []
        apps.onShimQuit = { closed.append($0) }
        let shim = Process()
        shim.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try shim.run()
        shim.waitUntilExit()
        apps.bind(pid: Int(shim.processIdentifier), stream: 5, pkg: "com.whatsapp")
        XCTAssertEqual(closed, [5])
    }

    func testBindingsFollowTheWindowIdentity() {
        let apps = DockApps(folder: folder, profile: Profile(name: "e2e")!)
        // A live pid: a bound pid that is already gone closes its window at once.
        let pid = Int(getpid())
        XCTAssertEqual(apps.boundStreams, [])
        apps.bind(pid: pid, stream: 2, pkg: "com.whatsapp")
        XCTAssertEqual(apps.stream(forPid: pid), 2)
        XCTAssertEqual(apps.binding(stream: 2)?.pkg, "com.whatsapp")
        XCTAssertEqual(apps.boundStreams, [2])
        // A second window of the same app takes the identity over.
        apps.rebind(pid: pid, to: 3)
        XCTAssertEqual(apps.binding(stream: 3)?.pkg, "com.whatsapp")
        apps.streamClosed(3)
        XCTAssertNil(apps.binding(stream: 3))
        XCTAssertTrue(apps.boundStreams.isEmpty, "the shim is told to exit with no window")
    }

    func testDockAutoSettingIsOnUntilTurnedOff() {
        let suite = "dockautotests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DockAutoSetting.isEnabled(in: defaults))
        defaults.set(false, forKey: DockAutoSetting.key)
        XCTAssertFalse(DockAutoSetting.isEnabled(in: defaults))
        defaults.set(true, forKey: DockAutoSetting.key)
        XCTAssertTrue(DockAutoSetting.isEnabled(in: defaults))
    }
}
