// What a bundle can do for Finder files (FilesBundleSupport.swift, design
// "Fixes 10-20"): a fake Info dictionary and path stand in for the bundle.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesBundleSupportTests: XCTestCase {
    private let info: [String: Any] = [filesGroupInfoKey: "group.dev.pocketdeck.mac.files"]

    func testAGroupAndAnExtensionAreBothNeeded() {
        XCTAssertTrue(FilesBundleSupport.supports(info: info, extensionExists: true))
        XCTAssertFalse(FilesBundleSupport.supports(info: info, extensionExists: false))
        XCTAssertFalse(FilesBundleSupport.supports(info: nil, extensionExists: true))
        XCTAssertFalse(FilesBundleSupport.supports(info: [filesGroupInfoKey: ""],
                                                   extensionExists: true))
        XCTAssertFalse(FilesBundleSupport.supports(info: [filesGroupInfoKey: 7],
                                                   extensionExists: true))
    }

    func testTheExtensionPathIsTheBundleShape() {
        XCTAssertEqual("Contents/PlugIns/Files.appex", FilesBundleSupport.extensionPath)
    }
}
