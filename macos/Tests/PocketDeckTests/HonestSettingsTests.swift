// Settings tell the truth about what this build can do (docs/NFR.md, AGENTS.md
// "honest settings"): a control whose capability is missing is disabled and
// says why, and no error copy suggests a restart unless a restart can change
// the state. The capability models are pure and injectable; the copy checks
// read the views' own source so a new sentence cannot slip past.

import AppKit
import SwiftUI
import XCTest
@testable import PocketDeck

@MainActor
final class HonestSettingsTests: XCTestCase {
    private var profile: Profile!

    override func setUp() async throws {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        profile = Profile(name: "honest-test-\(suffix)")
        XCTAssertNotNil(profile)
    }

    override func tearDown() async throws {
        if let profile {
            profile.defaults.removePersistentDomain(forName: profile.defaultsSuiteName!)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: base.appendingPathComponent(profile.supportDirectoryName))
        }
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketDeckTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("Sources/PocketDeck", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    /// The build variants are the pure support predicate's inputs: a bundle
    /// with the group and the appex, one without either, and one with the group
    /// but a missing appex.
    func testTheFilesExtensionCapabilityIsAHonestVariantModel() {
        let info = [filesGroupInfoKey: "group.dev.pocketdeck.test"]
        XCTAssertTrue(FilesBundleSupport.supports(info: info, extensionExists: true))
        XCTAssertFalse(FilesBundleSupport.supports(info: info, extensionExists: false))
        XCTAssertFalse(FilesBundleSupport.supports(info: nil, extensionExists: true))
        XCTAssertFalse(FilesBundleSupport.supports(info: [:], extensionExists: true))

        let unsupported = FilesDomainController(profile: profile, supported: false)
        XCTAssertFalse(unsupported.supported)
        XCTAssertFalse(unsupported.enabled)
        unsupported.setEnabled(true)
        XCTAssertFalse(unsupported.enabled, "an unsupported build never turns the switch on")
        XCTAssertEqual(unsupported.state, .off)
    }

    /// The Settings row: the toggle carries the capability as its disabled
    /// condition, and the unsupported branch explains it without a restart.
    func testTheFilesSwitchIsDisabledWithAReasonForABuildWithoutTheExtension() throws {
        let view = try source("FilesViews.swift")
        XCTAssertTrue(view.contains(".disabled(!controller.filesDomain.supported)"),
                      "the Finder-files toggle must be disabled when the build lacks the extension")
        XCTAssertTrue(view.contains("This copy of PocketDeck was built without Finder files."),
                      "the unsupported branch must say why")
        let unsupported = try XCTUnwrap(view.range(of: "This copy of PocketDeck was built without Finder files."))
        let branchStart = try XCTUnwrap(view.range(of: "} else {", options: .backwards,
                                        range: view.startIndex..<unsupported.lowerBound))
        let branch = view[branchStart.upperBound..<view.index(unsupported.upperBound, offsetBy: 0)]
        XCTAssertFalse(branch.lowercased().contains("restart"),
                       "a missing build feature cannot be fixed by restarting")
    }

    /// MCP is off by default; while off, Settings offers the switch and the
    /// local-only explanation, and no client snippet pretends it is running.
    func testMCPOffMeansNoSnippetAndAnExplanation() throws {
        let view = try source("SettingsViews.swift")
        XCTAssertTrue(view.contains("if controller.mcp.enabled"),
                      "the client snippet must live behind the on state")
        XCTAssertTrue(view.contains("Everything is off while this is off."))
        XCTAssertTrue(view.contains("It listens only on a private local socket, never on the network."))
        let automation = MCPAutomation()
        automation.configure(profile: profile, forced: false)
        XCTAssertFalse(automation.enabled, "the automation server is off by default")
        automation.start()
        if let path = automation.socketPath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "while off no socket exists at \(path)")
        }
        XCTAssertEqual(automation.clientCount, 0)
    }

    /// Error copy may say "restart" only where a restart changes the state.
    /// Today that is the failed File Provider add (a system state) alone.
    func testRestartCopyIsOnlyWhereRestartCanHelp() throws {
        let files = try source("FilesViews.swift")
        let lines = files.components(separatedBy: .newlines)
        let restartLines = lines.enumerated().filter { $0.element.lowercased().contains("restart") }
        XCTAssertEqual(restartLines.count, 1, "one user-facing restart sentence, no more")
        guard let line = restartLines.first else { return }
        let before = lines[..<line.offset].joined(separator: "\n")
        let failed = try XCTUnwrap(before.range(of: "if controller.filesDomain.state == .failed",
                                                options: .backwards))
        let tail = before[failed.upperBound...]
        XCTAssertFalse(tail.contains("if controller.filesDomain.state =="),
                       "the restart sentence must be in the failed branch, not a later one")

        // The other views: no restart advice at all.
        for name in ["SettingsViews.swift", "DeckViews.swift", "ConnectionFailure.swift",
                     "LinkWindow.swift", "HandoffWindow.swift"] {
            let text = try source(name)
            let userFacing = text.components(separatedBy: .newlines).filter {
                $0.contains("Text(\"") && $0.lowercased().contains("restart")
            }
            XCTAssertTrue(userFacing.isEmpty, "\(name) suggests a restart: \(userFacing)")
        }
    }
}
