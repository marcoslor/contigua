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

    private func cgImage(size: Int = 1024) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0, 0.8, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
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
        XCTAssertEqual(plist["PDLabel"] as? String, "Tom & \"Jerry\" <1>",
                       "the raw label survives a rebuild that only changes the origins")
        XCTAssertEqual(plist["PDOrigins"] as? [String], ["window"], "an automatic shim exists for its window")
        XCTAssertNil(plist["PDPinned"], "the origin set replaces the old marker")
        XCTAssertNil(plist["LSUIElement"], "the shim must show in the Dock and ⌘-Tab")
        var dock = spec()
        dock.origins = [.dock, .manual]
        XCTAssertEqual(dock.infoPlist["PDOrigins"] as? [String], ["dock", "manual"])
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
        pinned.origins = [.dock]
        let url = try DockShimBuilder.build(pinned, in: folder, shimBinary: try binary(), icon: cgImage())
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(bundle.bundleIdentifier, "dev.pocketdeck.dock.e2e.a1b2c3d4e5f60718.com-whatsapp")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, "\(label) (Pixel)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/PocketDeckShim").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).map(\.pkg), ["com.whatsapp"])
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).map(\.pinned), [true])
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "PDOrigins") as? [String], ["dock"])
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "PDLabel") as? String, label)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "PDIconVersion") as? Int, PhoneAppIcon.version)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "PDIconLayers") as? Bool, false,
                       "a default spec has no layers")
        let token = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "PDToken") as? String)
        XCTAssertTrue(DockToken.isWellFormed(token), "the bundle carries a token for the host's checks")
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).map(\.token), [token])
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: .default), [], "another profile's shims are not ours")
    }

    func testBuildWithoutIconStillWorksAndRebuildReplaces() throws {
        let binary = try binary()
        let first = try DockShimBuilder.build(spec(), in: folder, shimBinary: binary, icon: nil)
        let second = try DockShimBuilder.build(spec(), in: folder, shimBinary: binary, icon: cgImage())
        XCTAssertEqual(first, second)
        XCTAssertEqual(DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!).count, 1)
    }

    func testIcnsHasEveryStandardSizeFromOne1024Render() throws {
        let source = cgImage(size: 1024)
        let icns = try XCTUnwrap(DockShimBuilder.icns(from: source))
        XCTAssertEqual(Array(icns.prefix(4)), Array("icns".utf8))
        let image = try XCTUnwrap(NSImage(data: icns))
        let widths = Set(image.representations.map(\.pixelsWide))
        XCTAssertTrue(widths.isSuperset(of: [16, 32, 128, 256, 512, 1024]), "\(widths.sorted())")
        XCTAssertEqual(widths.max(), 1024, "the largest representation is the render, not a 96 px upscale")
    }

    /// A flat-only app's shim carries the shared renderer's output, not the
    /// phone's flat PNG (docs/design/dock.md §Icons): the render is shaped to
    /// the macOS squircle, so an opaque full-bleed flat's canvas corner is
    /// transparent in the `.icns` and the body is the flat's own colour.
    func testAFlatOnlyShimsIconComesFromTheRenderer() throws {
        let flat = flatPNG(red: 0, green: 128, blue: 96)
        let icon = try XCTUnwrap(PhoneAppIcon.render(fg: nil, bg: nil, flat: flat, px: 1024),
                                 "a flat-only app renders without layers")
        let url = try DockShimBuilder.build(spec(), in: folder, shimBinary: try binary(), icon: icon)
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        let image = try XCTUnwrap(NSImage(data: data))
        let rep = try XCTUnwrap(image.representations.first { $0.pixelsWide == 1024 } as? NSBitmapImageRep)
        let cg = try XCTUnwrap(rep.cgImage)
        XCTAssertEqual(pixel(cg, x: 2, y: 2).a, 0, "the renderer's squircle, not the bare square")
        let centre = pixel(cg, x: 512, y: 512)
        XCTAssertEqual(centre.r, 0)
        XCTAssertEqual(centre.g, 128)
        XCTAssertEqual(centre.b, 96)
        XCTAssertEqual(centre.a, 255)
    }

    private func flatPNG(size: Int = 96, red: UInt8, green: UInt8, blue: UInt8) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(red) / 255, CGFloat(green) / 255,
                                                                    CGFloat(blue) / 255, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    private func pixel(_ cg: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y),
                                        width: cg.width, height: cg.height))
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    // MARK: Cleanup decisions

    private func record(_ pkg: String, device: String = "d1", name: String, origins: DockOriginSet = .window,
                        label: String = "") -> DockShimRecord {
        DockShimRecord(url: URL(fileURLWithPath: "/x/\(pkg)-\(device).app"), deviceId: device, pkg: pkg,
                       profile: "e2e", name: name, origins: origins, label: label,
                       token: String(repeating: "a", count: 32))
    }

    private func app(_ pkg: String, _ label: String) -> AppInfo {
        AppInfo(json: ["pkg": pkg, "label": label])!
    }

    func testUninstalledAppsAreRemovedRenamedOnesRebuilt() {
        let records = [record("a", name: "A (Pixel)"), record("b", name: "B (Pixel)", origins: .all),
                       record("c", name: "C (Pixel)"), record("a", device: "d2", name: "A (Other)")]
        let plan = DockCleanup.plan(records: records, deviceId: "d1",
                                    apps: [app("a", "A"), app("c", "Cee")], phoneName: "Pixel")
        XCTAssertEqual(plan, [.remove(records[1].url),
                              .rebuild(records[2], label: "Cee", origins: .window)])
    }

    func testPhoneRenameRebuildsEveryShimOfThatPhone() {
        let records = [record("a", name: "A (Pixel)"), record("b", name: "B (Pixel)")]
        let plan = DockCleanup.plan(records: records, deviceId: "d1", apps: [app("a", "A"), app("b", "B")],
                                    phoneName: "Work phone")
        XCTAssertEqual(plan, [.rebuild(records[0], label: "A", origins: .window),
                              .rebuild(records[1], label: "B", origins: .window)])
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
                       [.rebuild(legacy, label: "A", origins: .window)])
    }

    /// An app list without the app drops Save all's and the manual reason but
    /// keeps a shim the Dock or an open window holds (docs/design/dock.md
    /// §Shortcuts).
    func testAnUninstalledAppKeepsOnlyTheDockAndWindowReasons() {
        let records = [record("a", name: "A (P)", origins: [.all, .manual, .window]),
                       record("b", name: "B (P)", origins: [.all, .manual]),
                       record("c", name: "C (P)", origins: [.dock])]
        let plan = DockCleanup.plan(records: records, deviceId: "d1", apps: [app("c", "C")],
                                    phoneName: "P", saveAll: true)
        XCTAssertEqual(plan, [.rebuild(records[0], label: "", origins: .window),
                              .remove(records[1].url),
                              .rebuild(records[2], label: "C", origins: [.dock, .all])])
        XCTAssertEqual(DockCleanup.plan(records: [records[1]], deviceId: "d1", apps: [],
                                        phoneName: "P"), [.remove(records[1].url)])
    }

    /// Save all adds `all` to every shim on a refresh and removes only `all`
    /// when the switch is off.
    func testSaveAllAddsAllOnARefreshAndRemovesOnlyAll() {
        let dock = record("a", name: "A (P)", origins: [.dock])
        let window = record("b", name: "B (P)", origins: [.window])
        let on = DockCleanup.plan(records: [dock, window], deviceId: "d1", apps: [app("a", "A"), app("b", "B")],
                                  phoneName: "P", saveAll: true)
        XCTAssertEqual(on, [.rebuild(dock, label: "A", origins: [.dock, .all]),
                            .rebuild(window, label: "B", origins: [.window, .all])])
        var kept = dock
        kept.origins.insert(.all)
        let off = DockCleanup.plan(records: [kept], deviceId: "d1", apps: [app("a", "A")],
                                   phoneName: "P", saveAll: false)
        XCTAssertEqual(off, [.rebuild(kept, label: "A", origins: .dock)])
    }

    func testSaveAllPlanIsOnEveryAppOffOnlyAll() {
        let records = [record("a", name: "A (P)", origins: [.dock]),
                       record("b", name: "B (P)", origins: [.all])]
        let apps = [app("a", "A"), app("b", "B"), app("c", "C")]
        XCTAssertEqual(DockSaveAll.plan(apps: apps, records: records, deviceId: "d1", on: true),
                       [DockSaveAllStep(pkg: "a", label: "A", origins: [.dock, .all], action: .write),
                        DockSaveAllStep(pkg: "c", label: "C", origins: .all, action: .write)])
        XCTAssertEqual(DockSaveAll.plan(apps: apps, records: records, deviceId: "d1", on: false),
                       [DockSaveAllStep(pkg: "b", label: "", origins: [], action: .remove)],
                       "off takes only `all`; a dock-only shim is not rewritten")
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

    func testTurningTheSettingOffStopsOnlyShimsOfWindows() {
        let records = [record("a", name: "A (P)"), record("b", name: "B (P)", origins: .dock),
                       record("c", device: "d2", name: "C (Q)")]
        XCTAssertEqual(DockQuit.plan(records: records).map(\.pkg), ["a", "c"],
                       "shims added by hand are not stopped by the setting")
    }

    func testLegacyShimsMigratePinnedToDockAndUnpinnedToWindow() throws {
        // Bundles from before origins: a missing PDPinned meant a hand-added
        // Dock app (true was the old default); false was an automatic identity.
        let url = try DockShimBuilder.build(spec(), in: folder, shimBinary: try binary(), icon: nil)
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: try Data(contentsOf: plistURL),
                                                                        format: nil) as? [String: Any])
        plist.removeValue(forKey: "PDOrigins")
        plist.removeValue(forKey: "PDPinned")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        var records = DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!)
        XCTAssertEqual(records.map(\.origins), [.dock])

        plist["PDPinned"] = false
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        records = DockShimBuilder.records(in: folder, profile: Profile(name: "e2e")!)
        XCTAssertEqual(records.map(\.origins), [.window])
        XCTAssertEqual(DockQuit.plan(records: records).count, 1,
                       "a migrated automatic identity still stops with the setting")
    }

    // MARK: The origin machine (docs/design/dock.md §Shortcuts)

    /// Every event against every starting set that matters: empty, each single
    /// origin, and the combinations that remove one while others stay.
    func testEveryOriginTransition() {
        typealias Case = (DockOriginSet, DockShimEvent, DockOriginSet, DockShimAction)
        let cases: [Case] = [
            // Add.
            ([], .add(.dock), .dock, .write),
            ([], .add(.manual), .manual, .write),
            ([], .add(.all), .all, .write),
            ([], .add(.window), .window, .write),
            ([.window], .add(.dock), [.dock, .window], .write),
            ([.dock, .manual], .add(.all), [.dock, .manual, .all], .write),
            ([.dock], .add(.dock), .dock, .none),
            ([.all, .window], .add(.manual), [.manual, .all, .window], .write),
            // Remove.
            ([.dock], .remove(.dock), [], .remove),
            ([.all], .remove(.all), [], .remove),
            ([.dock, .manual], .remove(.dock), .manual, .write),
            ([.dock, .all], .remove(.all), .dock, .write),
            ([.window], .remove(.dock), .window, .none),
            ([], .remove(.manual), [], .none),
            // Reconcile: installed.
            ([.all], .reconcile(saveAll: true, installed: true), .all, .none),
            ([], .reconcile(saveAll: true, installed: true), .all, .write),
            ([.window], .reconcile(saveAll: true, installed: true), [.window, .all], .write),
            ([.dock, .all], .reconcile(saveAll: false, installed: true), .dock, .write),
            ([.all], .reconcile(saveAll: false, installed: true), [], .remove),
            ([.manual], .reconcile(saveAll: false, installed: true), .manual, .none),
            // Reconcile: gone.
            ([.all, .manual], .reconcile(saveAll: true, installed: false), [], .remove),
            ([.all, .window], .reconcile(saveAll: true, installed: false), .window, .write),
            ([.manual, .dock], .reconcile(saveAll: false, installed: false), .dock, .write),
            ([.dock], .reconcile(saveAll: true, installed: false), .dock, .none),
            // Forget.
            ([.dock, .manual, .all, .window], .forget, [], .remove),
            ([], .forget, [], .none),
        ]
        for (start, event, wanted, action) in cases {
            let decision = DockOrigins.applying(event, to: start)
            XCTAssertEqual(decision.origins, wanted, "origins after \(event) from \(start.names)")
            XCTAssertEqual(decision.action, action, "action after \(event) from \(start.names)")
        }
    }

    func testOriginSetRoundTripsAndKeepsItsOrder() {
        let set: DockOriginSet = [.window, .dock, .all]
        XCTAssertEqual(set.names, ["dock", "all", "window"])
        XCTAssertEqual(DockOriginSet.parse(set.names), set)
        XCTAssertEqual(DockOriginSet.parse(["nonsense", "manual"]), .manual)
        XCTAssertEqual(DockOriginSet.parse([]), [])
        XCTAssertEqual(DockOriginSet.migrated(names: nil, pinned: true), .dock)
        XCTAssertEqual(DockOriginSet.migrated(names: nil, pinned: false), .window)
        XCTAssertEqual(DockOriginSet.migrated(names: ["manual"], pinned: true), .manual,
                       "the stored set wins over the old marker")
    }

    func testSaveAllSettingIsPerPhoneAndOffByDefault() {
        let suite = "savealltests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SaveAllShortcutsSetting.read(from: defaults, deviceId: "d1"))
        SaveAllShortcutsSetting.write(true, for: "d1", to: defaults)
        XCTAssertTrue(SaveAllShortcutsSetting.read(from: defaults, deviceId: "d1"))
        XCTAssertFalse(SaveAllShortcutsSetting.read(from: defaults, deviceId: "d2"))
        SaveAllShortcutsSetting.write(false, for: "d1", to: defaults)
        XCTAssertFalse(SaveAllShortcutsSetting.read(from: defaults, deviceId: "d1"))
        XCTAssertNil(defaults.object(forKey: SaveAllShortcutsSetting.key), "off leaves no empty dictionary")
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
                        shimIconVersion: Int = PhoneAppIcon.version, shimIconLayers: Bool = true,
                        hasLayers: Bool = true,
                        icon: DockFollow.IconState = .cached) -> DockFollow {
        DockFollow.decide(settingOn: settingOn, shimBinary: shimBinary, phoneKnown: phoneKnown,
                          shimExists: shimExists, shimRunning: shimRunning, shimHasIcon: shimHasIcon,
                          shimIconVersion: shimIconVersion, shimIconLayers: shimIconLayers,
                          hasLayers: hasLayers, icon: icon)
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

    func testAnIconFromAnOlderRendererOrAPlateIsRebuilt() {
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: true, shimIconVersion: 0, icon: .cached),
                       .createAndLaunch, "a bundle from before PDIconVersion is rebuilt")
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: true, shimIconVersion: PhoneAppIcon.version - 1,
                              icon: .cached), .createAndLaunch)
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: true, shimIconLayers: false, hasLayers: true,
                              icon: .cached), .createAndLaunch,
                       "the plate was drawn before the phone's layers arrived")
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: true, shimIconLayers: false, hasLayers: false,
                              icon: .cached), .launchExisting,
                       "a flat icon has no layers to wait for")
        XCTAssertEqual(decide(shimExists: true, shimHasIcon: true, shimIconVersion: 0, icon: .unknown), .wait,
                       "the layers may still arrive: do not rebuild into another plate")
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
