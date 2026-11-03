// The edge rule (docs/specs/controls.md): a Mac intent is applied on its edge,
// not re-asserted, and the person's own change on the phone stands until the
// Mac-side intent changes again. Every state accepts every event; the ignored
// ones are tested as ignored.

import XCTest
@testable import PocketDeck

final class ControlIntentTests: XCTestCase {

    private func step(_ state: ControlIntentState?, _ event: ControlIntentEvent)
        -> (state: ControlIntentState?, actions: [ControlIntentAction]) {
        ControlIntentMachine.transition(state, event)
    }

    // MARK: A Mac-side intent change

    func testIntentChangeIsSentAndRecorded() {
        let next = step(.applied("off"), .intentChanged("priority"))
        XCTAssertEqual(next.state, .applied("priority"))
        XCTAssertEqual(next.actions, [.send("priority")])
    }

    func testIntentChangeSendsEvenWhenThePhoneHasTheValue() {
        // A new Focus start is an edge even when it wants the mode the phone had
        // before the person changed it: "the next Focus start applies again".
        let next = step(.overridden("priority"), .intentChanged("priority"))
        XCTAssertEqual(next.state, .applied("priority"))
        XCTAssertEqual(next.actions, [.send("priority")])
    }

    func testPersonActionOnTheMacIsAlwaysAnEdge() {
        // The menu item, a Shortcut and a control all come through here: the
        // person asked again, so the same value is sent again.
        let next = step(.applied("priority"), .personAction("priority"))
        XCTAssertEqual(next.state, .applied("priority"))
        XCTAssertEqual(next.actions, [.send("priority")])
    }

    // MARK: The phone's own report

    func testReportOfOurValueStaysApplied() {
        let next = step(.applied("priority"), .phoneReported("priority"))
        XCTAssertEqual(next.state, .applied("priority"))
        XCTAssertEqual(next.actions, [])
    }

    func testReportOfAnotherValueIsThePersonsChange() {
        let next = step(.applied("priority"), .phoneReported("off"))
        XCTAssertEqual(next.state, .overridden("priority"))
        XCTAssertEqual(next.actions, [])
    }

    func testAnotherValueAgainKeepsThePersonsChange() {
        let next = step(.overridden("priority"), .phoneReported("alarms"))
        XCTAssertEqual(next.state, .overridden("priority"))
        XCTAssertEqual(next.actions, [])
    }

    func testThePhoneComingBackToOurValueIsAppliedAgain() {
        let next = step(.overridden("priority"), .phoneReported("priority"))
        XCTAssertEqual(next.state, .applied("priority"))
        XCTAssertEqual(next.actions, [])
    }

    func testReportWithoutMemoryChangesNothing() {
        let next = step(nil, .phoneReported("off"))
        XCTAssertNil(next.state)
        XCTAssertEqual(next.actions, [])
    }

    // MARK: A connection (the bug's own transition)

    func testFirstConnectSendsTheIntent() {
        // This phone never received a value: its first connect is the edge.
        let next = step(nil, .connected("priority"))
        XCTAssertEqual(next.state, .applied("priority"))
        XCTAssertEqual(next.actions, [.send("priority")])
    }

    func testReconnectAfterThePersonsChangeSendsNothing() {
        // The reported bug: Focus applies priority, the person turns DND off on
        // the phone, the session drops and comes back. The reconnect must not
        // turn it on again (the phone's `setByMac` was cleared by the person).
        let applied = step(.applied("priority"), .phoneReported("off"))
        XCTAssertEqual(applied.state, .overridden("priority"))
        let reconnect = step(applied.state, .connected("priority"))
        XCTAssertEqual(reconnect.state, .overridden("priority"))
        XCTAssertEqual(reconnect.actions, [])
    }

    func testReconnectAfterThePersonChangedItSendsNothingEvenWhenTheyUseAMode() {
        let overridden = step(.applied("priority"), .phoneReported("alarms")).state
        let reconnect = step(overridden, .connected("priority"))
        XCTAssertEqual(reconnect.actions, [])
        XCTAssertEqual(reconnect.state, .overridden("priority"))
    }

    func testReconnectAfterTheIntentChangedWhileApartSendsIt() {
        // The Focus ended while the phone was away: the stored intent differs
        // from what this phone had, so the connect applies it.
        let next = step(.applied("priority"), .connected("off"))
        XCTAssertEqual(next.state, .applied("off"))
        XCTAssertEqual(next.actions, [.send("off")])
    }

    func testReconnectAfterAnOverrideStillSendsANewIntent() {
        let overridden = step(.applied("priority"), .phoneReported("off")).state
        let next = step(overridden, .connected("alarms"))
        XCTAssertEqual(next.state, .applied("alarms"))
        XCTAssertEqual(next.actions, [.send("alarms")])
    }

    func testReconnectWithTheSameValueSendsNothing() {
        let next = step(.applied("off"), .connected("off"))
        XCTAssertEqual(next.state, .applied("off"))
        XCTAssertEqual(next.actions, [])
    }

    // MARK: The panel hold, the same machine

    func testPanelReopenAfterThePersonsWakeSendsNothing() {
        // Turn Off Phone Screen held the panel; the person's power press ended
        // it (the phone reported on); a reconnect reopens the mirror and must
        // not put the phone's screen back out.
        let held = step(.applied(PhonePanel.off.rawValue),
                        .personAction(PhonePanel.off.rawValue))
        XCTAssertEqual(held.actions, [.send(PhonePanel.off.rawValue)])
        let woken = step(held.state, .phoneReported(PhonePanel.on.rawValue))
        XCTAssertEqual(woken.state, .overridden(PhonePanel.off.rawValue))
        let reopen = step(woken.state, .connected(PhonePanel.off.rawValue))
        XCTAssertEqual(reopen.actions, [])
    }

    func testPanelClickAfterThePersonsWakeSendsAgain() {
        let woken = step(.applied(PhonePanel.off.rawValue), .phoneReported(PhonePanel.on.rawValue)).state
        let click = step(woken, .personAction(PhonePanel.off.rawValue))
        XCTAssertEqual(click.state, .applied(PhonePanel.off.rawValue))
        XCTAssertEqual(click.actions, [.send(PhonePanel.off.rawValue)])
    }

    func testPanelFirstOpenWithTheRememberedHoldSendsIt() {
        let next = step(nil, .connected(PhonePanel.off.rawValue))
        XCTAssertEqual(next.actions, [.send(PhonePanel.off.rawValue)])
    }

    // MARK: The memory

    func testStoreRoundTripPerPhone() {
        let suite = "control-intent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControlIntentStore(defaults: defaults, control: .dnd)

        XCTAssertNil(store.load(deviceId: "phone-a"))
        store.save(.applied("priority"), deviceId: "phone-a")
        store.save(.overridden("off"), deviceId: "phone-b")
        XCTAssertEqual(store.load(deviceId: "phone-a"), .applied("priority"))
        XCTAssertEqual(store.load(deviceId: "phone-b"), .overridden("off"))

        // A second store reads the same profile's memory: a restart keeps it.
        let reopened = ControlIntentStore(defaults: defaults, control: .dnd)
        XCTAssertEqual(reopened.load(deviceId: "phone-a"), .applied("priority"))
        // The other control has its own memory.
        XCTAssertNil(ControlIntentStore(defaults: defaults, control: .panel).load(deviceId: "phone-a"))

        store.save(nil, deviceId: "phone-a")
        XCTAssertNil(store.load(deviceId: "phone-a"))
        XCTAssertEqual(store.load(deviceId: "phone-b"), .overridden("off"))
    }

    func testStoreIgnoresAnEmptyDeviceId() {
        let suite = "control-intent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControlIntentStore(defaults: defaults, control: .dnd)
        store.save(.applied("priority"), deviceId: "")
        XCTAssertNil(store.load(deviceId: ""))
        XCTAssertNil(defaults.dictionary(forKey: "controlIntent.dnd"))
    }

    // MARK: The log's closed tokens

    func testEventTokensAndStateLabelsAreClosed() {
        XCTAssertEqual(ControlIntentEvent.intentChanged("priority").token, "intent")
        XCTAssertEqual(ControlIntentEvent.personAction("priority").token, "action")
        XCTAssertEqual(ControlIntentEvent.phoneReported("priority").token, "report")
        XCTAssertEqual(ControlIntentEvent.connected("priority").token, "connect")
        XCTAssertEqual(ControlIntentLabel.state(nil), "none")
        XCTAssertEqual(ControlIntentLabel.state(.applied("priority")), "applied")
        XCTAssertEqual(ControlIntentLabel.state(.overridden("priority")), "overridden")
        XCTAssertEqual(ControlKind.allCases.map(\.rawValue), ["dnd", "panel"])
    }
}
