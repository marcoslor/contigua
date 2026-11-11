// The Swift side of the NFR limits: the tests read docs/NFR.md's numbers from
// macos/scripts/nfr-limits.json instead of carrying their own copies (the one
// source of truth the shell checks use too). Tests only; the app never reads
// this file.

import Foundation

struct NFRTestLimits {
    static let shared = NFRTestLimits()

    private let values: [String: Any]

    private init() {
        let override = ProcessInfo.processInfo.environment["CONTIGUA_NFR_LIMITS"]
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ContiguaTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .appendingPathComponent("scripts/nfr-limits.json")
        let url = override.map { URL(fileURLWithPath: $0) } ?? source
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("NFR limits: cannot read \(url.path)")
        }
        values = object
    }

    func int(_ key: String) -> Int {
        guard let value = values[key] as? NSNumber else {
            preconditionFailure("NFR limits: \(key) is missing or not a number")
        }
        return value.intValue
    }

    func double(_ key: String) -> Double {
        guard let value = values[key] as? NSNumber else {
            preconditionFailure("NFR limits: \(key) is missing or not a number")
        }
        return value.doubleValue
    }

    /// The smallest supported screen, as [width, height].
    var smallestScreen: (width: Int, height: Int) {
        guard let value = values["layout_min_screen"] as? [NSNumber], value.count == 2 else {
            preconditionFailure("NFR limits: layout_min_screen must be [width, height]")
        }
        return (value[0].intValue, value[1].intValue)
    }
}
