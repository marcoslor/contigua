// Guard for the C2 rule (docs/design/camera.md): the app never touches a Mac
// camera. The Phone Camera window only decodes H.264 the phone sends, so the
// app target must not name a capture API or ask for camera permission — that
// is what keeps macOS from ever raising its camera prompt. The `cam-window`
// e2e check repeats this against the built bundle's binary and Info.plist.

import XCTest

final class NoMacCameraTests: XCTestCase {
    /// Names that only exist in Mac camera capture or a CoreMediaIO camera
    /// extension. Matched as plain text: an import, a type, or a comment that
    /// mentions one would fail the guard too, which is the point.
    private static let forbidden = [
        "AVCaptureDevice",
        "AVCaptureSession",
        "AVCaptureVideoDataOutput",
        "AVCaptureDeviceDiscoverySession",
        "CoreMediaIO",
        "CMIOExtension",
        "NSCameraUsageDescription",
    ]

    /// macos/ from this file's path: Tests/PocketDeckTests → Tests → macos.
    private var macos: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(under directory: URL) throws -> [URL] {
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    func testTheAppTargetNamesNoMacCameraAPI() throws {
        let sources = macos.appendingPathComponent("Sources/PocketDeck")
        let files = try swiftFiles(under: sources)
        XCTAssertGreaterThan(files.count, 50, "the app target's sources were not found under \(sources.path)")
        var hits: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for name in Self.forbidden where text.contains(name) {
                hits.append("\(file.lastPathComponent): \(name)")
            }
        }
        XCTAssertTrue(hits.isEmpty,
                      "the app target must never use a Mac camera API or ask for camera permission: \(hits)")
    }

    /// The bundle script writes the app's Info.plist; a camera usage string
    /// there is exactly what raises the permission prompt.
    func testTheAppBundleAsksForNoCameraPermission() throws {
        let script = try String(contentsOf: macos.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        XCTAssertFalse(script.contains("NSCameraUsageDescription"),
                       "the app bundle must not carry NSCameraUsageDescription")
    }

    /// The camera extension is an opt-in bundle of its own (C3, `--with-camera`)
    /// and must stay out of the plain app bundle.
    func testTheCameraExtensionIsNotBuiltByDefault() throws {
        let script = try String(contentsOf: macos.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("if [ \"$WITH_CAMERA\" = 1 ]; then"),
                      "the camera extension must stay behind --with-camera")
    }
}
