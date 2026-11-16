// The per-window agent hold (MCP-22, docs/specs/mcp.md "The agent hold"): a
// window an agent calls a tool on stays unpaused from the call's start until
// 15 s after it ends, covered or minimised alike, so it keeps sending frames.
// A pure `(state, event) -> (state, actions)` machine; every row is tested.

import Foundation

enum AgentHold {
    enum State: Equatable {
        case released
        case held(until: TimeInterval)
    }

    enum Event: Equatable {
        /// A tool naming the window started or ended at `now`.
        case agentCall(now: TimeInterval)
        /// The window's clock.
        case tick(now: TimeInterval)
        case windowClosed
    }

    enum Action: Equatable {
        /// Re-decide pause by StreamPause, which sees whether the hold is on.
        case reevaluatePause
    }

    /// MCP-22: the hold lasts 15 s after the call.
    static let holdSeconds: TimeInterval = 15

    static func next(_ state: State, _ event: Event) -> (State, [Action]) {
        switch (state, event) {
        case (.released, .agentCall(let now)):
            return (.held(until: now + holdSeconds), [.reevaluatePause])
        case (.held(let until), .agentCall(let now)):
            return (.held(until: max(until, now + holdSeconds)), [])
        case (.held(let until), .tick(let now)):
            return now >= until ? (.released, [.reevaluatePause]) : (state, [])
        case (.released, .tick):
            return (.released, [])
        case (.held, .windowClosed), (.released, .windowClosed):
            return (.released, [])
        }
    }

    static func isHeld(_ state: State) -> Bool {
        if case .held = state { return true }
        return false
    }
}
