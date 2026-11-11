import CryptoKit
import XCTest
@testable import Contigua

final class ApkBundleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stored (uncompressed) zip with exactly these entry names, written by hand so
    /// names `zip` would clean up (`../x`) can be tested.
    private func storedZip(_ files: [(String, Data)], name: String) throws -> URL {
        var out = Data(), directory = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        for (path, body) in files {
            let offset = out.count, nameBytes = Data(path.utf8)
            let local: [Data] = [le32(0x0403_4b50), le16(20), le16(0), le16(0), le32(0), le32(0),
                                 le32(body.count), le32(body.count), le16(nameBytes.count), le16(0), nameBytes, body]
            let central: [Data] = [le32(0x0201_4b50), le16(20), le16(20), le16(0), le16(0), le32(0), le32(0),
                                   le32(body.count), le32(body.count), le16(nameBytes.count), le16(0), le16(0),
                                   le16(0), le16(0), le32(0), le32(offset), nameBytes]
            local.forEach { out.append($0) }
            central.forEach { directory.append($0) }
        }
        let start = out.count
        let end: [Data] = [directory, le32(0x0605_4b50), le16(0), le16(0), le16(files.count), le16(files.count),
                           le32(directory.count), le32(start), le16(0)]
        end.forEach { out.append($0) }
        let url = dir.appendingPathComponent(name)
        try out.write(to: url)
        return url
    }

    /// A deflated zip made by the system `zip` tool from files in a scratch folder.
    private func deflatedZip(_ files: [(String, Data)], name: String) throws -> URL {
        let src = dir.appendingPathComponent("src-\(name)")
        for (path, body) in files {
            let file = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: file)
        }
        let url = dir.appendingPathComponent(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = src
        zip.arguments = ["-q", "-r", "-9", url.path] + files.map(\.0)
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return url
    }

    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private let manifest = Data(repeating: 3, count: 64)

    func testPlainApkIsOnePartNamedBase() throws {
        let url = try storedZip([("AndroidManifest.xml", manifest), ("classes.dex", Data([1, 2]))], name: "app.apk")
        let (bundle, _) = try ApkBundle.open(url)
        XCTAssertEqual(bundle.kind, .apk)
        XCTAssertEqual(bundle.parts.map(\.name), ["base.apk"])
        XCTAssertNil(bundle.parts[0].entry)
        XCTAssertEqual(bundle.totalBytes, try Data(contentsOf: url).count)
    }

    func testZipWithoutManifestIsNotAnApp() throws {
        let url = try storedZip([("readme.txt", Data("hi".utf8))], name: "fake.apk")
        XCTAssertThrowsError(try ApkBundle.open(url)) { XCTAssertEqual($0 as? ApkBundleError, .notAnApp) }
        let notZip = dir.appendingPathComponent("text.apk")
        try Data("plain text".utf8).write(to: notZip)
        XCTAssertThrowsError(try ApkBundle.open(notZip)) { XCTAssertEqual($0 as? ApkBundleError, .notAnApp) }
        let noApks = try storedZip([("notes.txt", Data([1]))], name: "empty.apks")
        XCTAssertThrowsError(try ApkBundle.open(noApks)) { XCTAssertEqual($0 as? ApkBundleError, .notAnApp) }
    }

    func testApksPicksSplitsBaseFirstAndSkipsStandalones() throws {
        let base = Data(repeating: 1, count: 5000), abi = Data(repeating: 2, count: 3000)
        let url = try deflatedZip([("toc.pb", Data([0])),
                                   ("splits/base-arm64_v8a.apk", abi),
                                   ("splits/base-master.apk", base),
                                   ("standalones/standalone-arm64_v8a.apk", Data([9]))], name: "app.apks")
        let (bundle, archive) = try ApkBundle.open(url)
        XCTAssertEqual(bundle.parts.map(\.name), ["base-master.apk", "base-arm64_v8a.apk"])
        XCTAssertEqual(bundle.totalBytes, 8000)
        let entry = try XCTUnwrap(archive.entries.first { $0.name == "splits/base-master.apk" })
        XCTAssertEqual(entry.method, 8)
        let out = dir.appendingPathComponent("out.apk")
        XCTAssertEqual(try archive.extract(entry, to: out), sha(base))
        XCTAssertEqual(try Data(contentsOf: out), base)
    }

    func testXapkUsesManifestPackageAsBase() throws {
        let json = Data(#"{"package_name":"com.example.tiny","version_name":"1.2"}"#.utf8)
        let url = try deflatedZip([("manifest.json", json), ("config.arm64_v8a.apk", Data([2])),
                                   ("com.example.tiny.apk", Data([1])), ("icon.png", Data([0])),
                                   ("Android/obb/com.example.tiny/main.1.obb", Data([7]))], name: "app.xapk")
        let (bundle, _) = try ApkBundle.open(url)
        XCTAssertEqual(bundle.kind, .xapk)
        XCTAssertEqual(bundle.parts.map(\.name), ["com.example.tiny.apk", "config.arm64_v8a.apk"])
    }

    func testPathTraversalRejectsTheWholeBundle() throws {
        for evil in ["../evil.apk", "/abs.apk", "splits/../../x.apk", "a\\b.apk"] {
            let url = try storedZip([("base.apk", Data([1])), (evil, Data([2]))], name: "evil.apks")
            XCTAssertThrowsError(try ApkBundle.open(url), evil) {
                XCTAssertEqual($0 as? ApkBundleError, .unsafeEntry(evil))
            }
        }
    }

    func testOversizedBundleIsRefused() {
        let entries = [ZipEntry(name: "base.apk", method: 0, compressedSize: 1, size: ApkBundle.maxTotalBytes, localHeaderOffset: 0),
                       ZipEntry(name: "split_a.apk", method: 0, compressedSize: 1, size: 1, localHeaderOffset: 0)]
        XCTAssertThrowsError(try ApkBundle.plan(kind: .apks, entries: entries, fileSize: 2)) {
            XCTAssertEqual($0 as? ApkBundleError, .tooLarge)
        }
    }

    func testPartNamesArePlainAndUnique() throws {
        let entries = ["a/base.apk", "b/base.apk", "c/wéird name.apk"].map {
            ZipEntry(name: $0, method: 0, compressedSize: 1, size: 1, localHeaderOffset: 0)
        }
        let bundle = try ApkBundle.plan(kind: .apks, entries: entries, fileSize: 3)
        XCTAssertEqual(bundle.parts.map(\.name), ["base.apk", "_base.apk", "w_ird_name.apk"])
    }

    func testFailureCodesReadAsSentences() {
        XCTAssertEqual(ApkInstallMessage.failure(code: "INSTALL_FAILED_VERSION_DOWNGRADE"),
                       "A newer version of this app is already on the phone.")
        let signature = "This app is already on the phone with a different signature. Uninstall it on the phone first."
        XCTAssertEqual(ApkInstallMessage.failure(code: "INSTALL_FAILED_UPDATE_INCOMPATIBLE"), signature)
        XCTAssertEqual(ApkInstallMessage.failure(code: "failed", detail: "Package x signatures do not match previously installed version"),
                       signature)
        XCTAssertEqual(ApkInstallMessage.failure(code: "INSTALL_FAILED_INSUFFICIENT_STORAGE"), "Not enough storage on the phone.")
        XCTAssertEqual(ApkInstallMessage.failure(code: "INSTALL_FAILED_NO_MATCHING_ABIS"),
                       "This app doesn't support the phone's processor.")
        XCTAssertEqual(ApkInstallMessage.failure(code: "INSTALL_PARSE_FAILED_NOT_APK"), "That file isn't an Android app.")
        XCTAssertEqual(ApkInstallMessage.failure(code: "INSTALL_FAILED_SOMETHING_NEW"),
                       "The phone couldn't install it (INSTALL_FAILED_SOMETHING_NEW).")
        XCTAssertEqual(ApkInstallMessage.failure(code: "weird"), "The phone couldn't install it.")
        XCTAssertEqual(ApkInstallMessage.success(label: "Tiny", version: "1.2"), "Installed Tiny 1.2.")
        XCTAssertEqual(ApkInstallMessage.success(label: nil, version: nil), "Installed.")
    }
}
