// The Mac's half of the stream-strategy switches (ISS-40): presentation, pixel
// request and traffic class. Read from the app profile's defaults when a
// window opens or resizes (and when a session dials for `net`), never per
// frame. Every key defaults to today's behaviour.

import Darwin
import Foundation

struct MacStreamStrategy: Equatable {
    /// M1: show on arrival (today) or spread decoded samples over display
    /// refreshes.
    enum Present: String, Equatable {
        case immediate
        case paced
    }

    /// M2: ask for the window's backing pixels (today) or at most the panel's.
    enum Pixels: String, Equatable {
        case backing
        case panel
    }

    /// N1's Mac side: the socket's service class.
    enum Net: String, Equatable {
        case `default`
        case video
    }

    static let presentKey = "stream.present"
    static let pixelsKey = "stream.pixels"
    static let netKey = "stream.net"

    var present: Present = .immediate
    var pixels: Pixels = .backing
    var net: Net = .default

    var isDefault: Bool {
        present == .immediate && pixels == .backing && net == .default
    }

    /// N1's Mac half: the `SO_NET_SERVICE_TYPE` value the dial sets before
    /// connect, nil when the socket stays at the system default (unmarked).
    var socketServiceType: Int32? {
        net == .video ? NET_SERVICE_TYPE_VI : nil
    }

    /// The one line's value: `default`, or every key's closed token. A single
    /// switched key still prints all three so the line always says the whole
    /// strategy.
    var logValue: String {
        guard !isDefault else { return "default" }
        return "present=\(present.rawValue) pixels=\(pixels.rawValue) net=\(net.rawValue)"
    }

    func windowLine(stream: UInt32) -> String {
        "stream \(stream) mac strategy: \(logValue)"
    }

    /// The keys as the defaults store returns them. Only a string equal to a
    /// closed token counts; anything else (a number, a wrong case, an empty
    /// value) keeps that key's default.
    static func read(_ value: (String) -> Any?) -> MacStreamStrategy {
        func token(_ key: String) -> String? {
            value(key) as? String
        }
        return MacStreamStrategy(
            present: Present(rawValue: token(presentKey) ?? "") ?? .immediate,
            pixels: Pixels(rawValue: token(pixelsKey) ?? "") ?? .backing,
            net: Net(rawValue: token(netKey) ?? "") ?? .default)
    }

    /// The app profile's suite (the person's `dev.pocketdeck.mac`, the e2e's
    /// `dev.pocketdeck.mac.<profile>`).
    static func read(from defaults: UserDefaults) -> MacStreamStrategy {
        read { defaults.object(forKey: $0) }
    }
}
