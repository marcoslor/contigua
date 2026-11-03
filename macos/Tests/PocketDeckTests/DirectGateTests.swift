import Foundation
import XCTest

/// docs/design/direct-link.md §1.3: the public build must not carry a line of
/// direct-link code. The check scans the sources it is about to compile, not
/// the build's output, so a leaked comment is caught too.
final class DirectGateTests: XCTestCase {
    private static let forbidden = ["WiFiPeerToPeer", "WiFiAware", "nan0",
                                    "wifi-aware", "pocketdeck-directd",
                                    "POCKETDECK_DIRECT"]

    /// One line the scan looked at.
    struct Finding: CustomStringConvertible {
        let path: String
        let line: Int
        let text: String
        var description: String { "\(path):\(line): \(text)" }
    }

    func testPublicSourcesCarryNoDirectCode() throws {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketDeckTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
        let sources = macos.appendingPathComponent("Sources")
        let leaks = try Self.scan(directory: sources)
        XCTAssertTrue(leaks.isEmpty,
                      "direct-link code outside #if POCKETDECK_DIRECT:\n"
                      + leaks.map(\.description).joined(separator: "\n"))
    }

    /// The positive control: if the scanner cannot see a plain leak, the check
    /// above proves nothing. These are built at run time so this file itself
    /// stays inside the rule it enforces.
    func testScannerCatchesALeak() throws {
        let name = ["nan", "0"].joined()
        let text = """
        // a plain comment mentioning \(name)
        let interface = "\(name)"
        """
        let leaks = Self.scan(text: text, path: "Leak.swift")
        XCTAssertEqual(leaks.count, 2, "the scanner must catch every ungated line")

        let gated = """
        #if \(Self.flag)
        let interface = "\(name)"
        #endif
        let other = 1
        """
        XCTAssertTrue(Self.scan(text: gated, path: "Gated.swift").isEmpty)
    }

    private static var flag: String { ["POCKETDECK", "DIRECT"].joined(separator: "_") }

    private static func scan(directory: URL) throws -> [Finding] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var findings: [Finding] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            findings += scan(text: text, path: file.lastPathComponent)
        }
        return findings
    }

    /// Line-based, because the gate is textual: a string in a comment counts.
    static func scan(text: String, path: String) -> [Finding] {
        struct Frame { var gated: Bool; var active: Bool }
        var stack: [Frame] = []
        var findings: [Finding] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isDirective = line.hasPrefix("#if") || line.hasPrefix("#else")
                || line.hasPrefix("#endif")
            if line.hasPrefix("#if") || line.hasPrefix("#elseif") {
                stack.append(Frame(gated: line.contains(flag), active: true))
            } else if line.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1].active = false }
            } else if line.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            }
            guard !isDirective else { continue }
            guard !stack.contains(where: { $0.gated && $0.active }) else { continue }
            if forbidden.contains(where: { line.contains($0) }) {
                findings.append(Finding(path: path, line: index + 1, text: line))
            }
        }
        return findings
    }
}
