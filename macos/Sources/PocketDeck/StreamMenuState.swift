// What the View menu shows about the key stream window. SwiftUI's menu
// commands cannot see AppKit windows, so the window controllers publish here.

import Observation

@Observable
final class StreamMenuState {
    static let shared = StreamMenuState()

    /// A stream window is key: the per-window items are enabled.
    var hasStream = false
    /// The key stream window's style (the Window Style radio items follow it).
    var style: WindowStyle = .standard
    var showTouches = false

    private init() {}
}
