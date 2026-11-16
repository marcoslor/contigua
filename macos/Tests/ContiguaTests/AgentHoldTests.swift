// MCP-22: the agent hold (docs/specs/mcp.md "The agent hold"), one test per
// row of the table: a pure (state, event) -> (state, actions) machine.

import XCTest
@testable import Contigua

final class AgentHoldTests: XCTestCase {
    private func step(_ state: AgentHold.State, _ event: AgentHold.Event)
        -> (AgentHold.State, [AgentHold.Action]) {
        AgentHold.next(state, event)
    }

    // [MCP-22] Released · agentCall(now) → Held(now + 15), re-evaluate pause.
    func testACallHoldsForFifteenSeconds() {
        let (held, actions) = step(.released, .agentCall(now: 100))
        XCTAssertEqual(held, .held(until: 115))
        XCTAssertEqual(actions, [.reevaluatePause])
        let (still, none) = step(held, .tick(now: 114.9))
        XCTAssertEqual(still, .held(until: 115))
        XCTAssertEqual(none, [])
        let (released, after) = step(still, .tick(now: 115))
        XCTAssertEqual(released, .released)
        XCTAssertEqual(after, [.reevaluatePause])
    }

    // [MCP-22] Held · agentCall(now) → Held(now + 15), no action.
    func testASecondCallExtendsTheHold() {
        let (state, actions) = step(.held(until: 115), .agentCall(now: 110))
        XCTAssertEqual(state, .held(until: 125))
        XCTAssertEqual(actions, [])
    }

    // [MCP-22] A later call never shortens the hold.
    func testAnEarlierClockNeverShortensTheHold() {
        let (state, _) = step(.held(until: 125), .agentCall(now: 100))
        XCTAssertEqual(state, .held(until: 125))
    }

    // [MCP-22] Held · windowClosed → Released, no action.
    func testClosingAHeldWindowReleasesIt() {
        let (state, actions) = step(.held(until: 115), .windowClosed)
        XCTAssertEqual(state, .released)
        XCTAssertEqual(actions, [])
    }

    // [MCP-22] Released · windowClosed → Released, no action.
    func testClosingAReleasedWindowDoesNothing() {
        let (state, actions) = step(.released, .windowClosed)
        XCTAssertEqual(state, .released)
        XCTAssertEqual(actions, [])
    }

    // [MCP-22] Released · tick → Released, ignored.
    func testATickWhileReleasedIsIgnored() {
        let (state, actions) = step(.released, .tick(now: 999))
        XCTAssertEqual(state, .released)
        XCTAssertEqual(actions, [])
    }

    // [MCP-22] Held · tick(now < until) → Held, no action.
    func testATickBeforeTheEndKeepsTheHold() {
        let (state, actions) = step(.held(until: 115), .tick(now: 114.99))
        XCTAssertEqual(state, .held(until: 115))
        XCTAssertEqual(actions, [])
    }
}
