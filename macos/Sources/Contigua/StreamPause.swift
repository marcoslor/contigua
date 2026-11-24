// Whether a stream window's picture must pause.
//
// The person's 10-27 log shows the loop behind a flickering menu: a menu covered
// the window, the window went "not visible", the Mac paused the stream, the
// pause changed state, the menu was rebuilt, the submenu closed, the window was
// visible again, and it unpaused. A menu is transient — it is over a window for
// a moment and says nothing about whether the person stopped watching — so it
// never pauses a stream.

import Foundation

enum StreamPause {
    /// The one rule, from the window's own signals.
    static func shouldPause(miniaturized: Bool,
                            key: Bool,
                            main: Bool,
                            occludedVisible: Bool,
                            menuTracking: Bool,
                            agentHold: Bool) -> Bool {
        // MCP-22: an agent's hold wins over every other rule, so a covered or
        // minimised window keeps streaming while an agent uses it.
        if agentHold { return false }
        // A minimised window is really gone, whatever is tracking.
        if miniaturized { return true }
        // `occlusionState` can spuriously report !visible for the frontmost
        // window, which would detach its encoder.
        if key || main { return false }
        // The person is in a menu, and that menu is what covers us.
        if menuTracking { return false }
        return !occludedVisible
    }
}
