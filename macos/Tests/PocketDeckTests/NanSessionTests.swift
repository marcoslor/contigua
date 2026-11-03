#if POCKETDECK_DIRECT
import Foundation
import XCTest
@testable import PocketDeckDirectCore

/// The Mac's NAN session (docs/design/direct-link.md §2.2, transport
/// DIRECT-18): every state × event pair, the actions the port is asked to
/// perform, and the peer shape handed to the link layer.
final class NanSessionTests: XCTestCase {
    private let attempt = NanAttempt(service: "_pocketdeck-nan._tcp",
                                     windows: [ssi(0x11), ssi(0x12)],
                                     passphrase: "test-passphrase")
    private let ticked = NanAttempt(service: "_pocketdeck-nan._tcp",
                                    windows: [ssi(0x31)],
                                    passphrase: "test-passphrase")
    private let peer = DirectPeerSpec(interface: "nan0",
                                      mac: "66:65:74:68:00:01",
                                      linkLocal: "fe80::1")

    private let idle = NanSessionState.idle
    private var subscribing: NanSessionState { .subscribing(attempt) }
    private var discovered: NanSessionState { .discovered(attempt, token: 7) }
    private var starting: NanSessionState { .dataSessionStarting(attempt, token: 7) }
    private var up: NanSessionState { .up(peer) }
    private let lost = NanSessionState.lost
    private let blocked = NanSessionState.blocked(.ndpRefused)

    private let discoveryMatch = NanDiscovery(token: 7, ssi: ssi(0x11))
    private let discoveryMiss = NanDiscovery(token: 8, ssi: ssi(0x99))

    private var start: NanSessionEvent {
        .start(service: attempt.service, windows: attempt.windows,
               passphrase: attempt.passphrase)
    }
    private var windows: NanSessionEvent { .ssiWindows(ticked.windows) }
    private var match: NanSessionEvent { .discovered(discoveryMatch) }
    private var miss: NanSessionEvent { .discovered(discoveryMiss) }
    private var reportStarting: NanSessionEvent { .dataSession(.starting) }
    private var reportUp: NanSessionEvent {
        .dataSession(.up(mac: "66:65:74:68:00:01", linkLocal: "fe80::1%nan0"))
    }
    private var reportFailed: NanSessionEvent { .dataSession(.failed(.ndpRefused)) }
    private var reportLost: NanSessionEvent { .dataSession(.lost) }
    private var timeout: NanSessionEvent { .ndpTimeout }
    private var stop: NanSessionEvent { .stop }
    private var unavailable: NanSessionEvent { .toolkit(.unavailable) }
    private var subscribeFailed: NanSessionEvent { .toolkit(.subscribeFailed) }
    private var startFailed: NanSessionEvent { .toolkit(.dataSessionFailed) }

    private var subscribeAction: NanSessionAction {
        .subscribe(service: attempt.service, windows: attempt.windows)
    }
    private var updateAction: NanSessionAction { .updateWindows(ticked.windows) }
    private var startSessionAction: NanSessionAction {
        .startDataSession(token: 7, passphrase: attempt.passphrase)
    }
    private var peerUpAction: NanSessionAction { .peerUp(peer) }
    private var lostActions: [NanSessionAction] { [.peerLost, .stopDataSession, .unsubscribe] }

    private func transition(_ state: NanSessionState, _ event: NanSessionEvent,
                            _ next: NanSessionState, _ actions: [NanSessionAction],
                            file: StaticString = #filePath, line: UInt = #line) {
        let step = NanSessionMachine.step(state, event, interface: "nan0")
        XCTAssertEqual(step.0, next, "\(NanSessionMachine.describe(state, event, step.0))",
                       file: file, line: line)
        XCTAssertEqual(step.1, actions, "\(NanSessionMachine.describe(state, event, step.0))",
                       file: file, line: line)
    }

    // MARK: every state × event

    func testEveryTransitionAndEveryIgnoredEvent() {
        // idle: nothing but start does anything.
        transition(idle, start, subscribing, [subscribeAction])
        for event in [windows, match, miss, reportStarting, reportUp, reportFailed,
                      reportLost, timeout, stop, unavailable, subscribeFailed, startFailed] {
            transition(idle, event, idle, [])
        }

        // subscribing: a matching discovery starts the NDP; the timer and the
        // toolkit's refusals block; everything else waits.
        transition(subscribing, start, subscribing, [])
        transition(subscribing, windows, .subscribing(ticked), [updateAction])
        transition(subscribing, match, discovered, [startSessionAction])
        for event in [miss, reportStarting, reportUp, reportFailed, reportLost] {
            transition(subscribing, event, subscribing, [])
        }
        transition(subscribing, timeout, .blocked(.ndpTimeout), [
            .unsubscribe, .failed(.ndpTimeout)
        ])
        transition(subscribing, stop, idle, [.unsubscribe])
        transition(subscribing, unavailable, .blocked(.notReady), [
            .unsubscribe, .failed(.notReady)
        ])
        for event in [subscribeFailed, startFailed] {
            transition(subscribing, event, .blocked(.ndpRefused), [
                .unsubscribe, .failed(.ndpRefused)
            ])
        }

        // discovered: a start report moves to dataSessionStarting; an up that
        // arrives first is accepted; the teardown actions are returned once.
        transition(discovered, start, discovered, [])
        transition(discovered, windows, .discovered(ticked, token: 7), [updateAction])
        transition(discovered, match, discovered, [])
        transition(discovered, miss, discovered, [])
        transition(discovered, reportStarting, starting, [])
        transition(discovered, reportUp, up, [peerUpAction])
        transition(discovered, reportFailed, .blocked(.ndpRefused), [
            .stopDataSession, .unsubscribe, .failed(.ndpRefused)
        ])
        transition(discovered, reportLost, discovered, [])
        transition(discovered, timeout, .blocked(.ndpTimeout), [
            .stopDataSession, .unsubscribe, .failed(.ndpTimeout)
        ])
        transition(discovered, stop, idle, [.stopDataSession, .unsubscribe])
        for event in [unavailable, subscribeFailed, startFailed] {
            transition(discovered, event, .blocked(.ndpRefused), [
                .stopDataSession, .unsubscribe, .failed(.ndpRefused)
            ])
        }

        // dataSessionStarting: the up report hands the peer over once.
        transition(starting, start, starting, [])
        transition(starting, windows, .dataSessionStarting(ticked, token: 7), [updateAction])
        for event in [match, miss, reportStarting] {
            transition(starting, event, starting, [])
        }
        transition(starting, reportUp, up, [peerUpAction])
        transition(starting, reportFailed, .blocked(.ndpRefused), [
            .stopDataSession, .unsubscribe, .failed(.ndpRefused)
        ])
        transition(starting, reportLost, .blocked(.ndpRefused), [
            .stopDataSession, .unsubscribe, .failed(.ndpRefused)
        ])
        transition(starting, timeout, .blocked(.ndpTimeout), [
            .stopDataSession, .unsubscribe, .failed(.ndpTimeout)
        ])
        transition(starting, stop, idle, [.stopDataSession, .unsubscribe])
        for event in [unavailable, subscribeFailed, startFailed] {
            transition(starting, event, .blocked(.ndpRefused), [
                .stopDataSession, .unsubscribe, .failed(.ndpRefused)
            ])
        }

        // up: a second dial reuses the live NDP; a lost report tears it down.
        for event in [start, match, miss, reportStarting, reportUp, reportFailed,
                      timeout, unavailable, subscribeFailed, startFailed] {
            transition(up, event, up, [])
        }
        transition(up, windows, up, [updateAction])
        transition(up, reportLost, lost, lostActions)
        transition(up, stop, idle, lostActions)

        // lost: the radio is quiet until the next dial; late reports are stale.
        transition(lost, start, subscribing, [subscribeAction])
        for event in [windows, match, miss, reportStarting, reportUp, reportFailed,
                      reportLost, timeout, unavailable, subscribeFailed, startFailed] {
            transition(lost, event, lost, [])
        }
        transition(lost, stop, idle, [])

        // blocked: a new dial is a new attempt; a stop is already torn down.
        transition(blocked, start, subscribing, [subscribeAction])
        for event in [windows, match, miss, reportStarting, reportUp, reportFailed,
                      reportLost, timeout, unavailable, subscribeFailed, startFailed] {
            transition(blocked, event, blocked, [])
        }
        transition(blocked, stop, idle, [])
    }

    func testTheTimeoutIsTwentySeconds() {
        XCTAssertEqual(NanLimits.ndpTimeoutSeconds, 20)
    }

    // MARK: the peer handed to the link layer

    func testUpIsTheSamePeerShapeTheTestPeerOpCarries() throws {
        let step = NanSessionMachine.step(starting, reportUp, interface: "nan0")
        guard case .up(let spec) = step.0 else { return XCTFail("not up") }
        // The `peer` op's validators, so the NAN report and the feth peer
        // cannot drift apart (DirectPeerSpec is what the daemon sets).
        XCTAssertTrue(isMAC(spec.mac), spec.mac)
        let bytes = try XCTUnwrap(IPv6Address.parse(spec.linkLocal))
        XCTAssertEqual(IPv6Address.format(bytes), "fe80::1")
        XCTAssertEqual(spec, peer)
        XCTAssertEqual(step.1, [.peerUp(peer)])
    }

    func testAMalformedPeerIsRefusedAsAnNdpRefusal() {
        for report in [
            NanDataSessionReport.up(mac: "66:65:74:68:00", linkLocal: "fe80::1"),
            NanDataSessionReport.up(mac: "66:65:74:68:00:01", linkLocal: "not-an-address"),
            NanDataSessionReport.up(mac: "66:65:74:68:00:00", linkLocal: "")
        ] {
            let step = NanSessionMachine.step(starting, .dataSession(report), interface: "nan0")
            XCTAssertEqual(step.0, .blocked(.ndpRefused), "\(report)")
            XCTAssertEqual(step.1, [.stopDataSession, .unsubscribe, .failed(.ndpRefused)])
        }
    }

    func testTheInterfaceComesFromTheHelperNotTheToolkit() throws {
        let step = NanSessionMachine.step(starting, reportUp, interface: "feth0")
        guard case .up(let spec) = step.0 else { return XCTFail("not up") }
        XCTAssertEqual(spec.interface, "feth0")
    }

    // MARK: SSI matching

    func testOnlyTheAcceptedWindowsStartTheDataSession() {
        XCTAssertEqual(NanSessionMachine.step(subscribing, match, interface: "nan0").0,
                       discovered)
        XCTAssertEqual(NanSessionMachine.step(subscribing, miss, interface: "nan0").0,
                       subscribing)
        XCTAssertEqual(NanSessionMachine.step(subscribing, miss, interface: "nan0").1, [])
    }

    func testAWindowTickReplacesTheAcceptedSet() {
        let step = NanSessionMachine.step(subscribing, windows, interface: "nan0")
        guard case .subscribing(let next) = step.0 else { return XCTFail("not subscribing") }
        XCTAssertEqual(next.windows, [ssi(0x31)])
        XCTAssertEqual(step.1, [.updateWindows(ticked.windows)])
        // The old window no longer matches.
        XCTAssertEqual(NanSessionMachine.step(step.0, match, interface: "nan0").0,
                       .subscribing(ticked))
    }

    // MARK: the driver over the port

    func testTheDriverPerformsThePortActionsAndLogsThePath() throws {
        let port = FakeNanPort()
        let log = LogCapture()
        let session = NanSession(port: port, interface: "nan0", log: { log.append($0) })

        XCTAssertEqual(session.handle(start).state, subscribing)
        XCTAssertEqual(session.handle(reportStarting).state, subscribing)  // ignored
        XCTAssertEqual(session.handle(match).state, discovered)
        XCTAssertEqual(session.handle(reportStarting).state, starting)
        XCTAssertEqual(session.handle(reportUp).state, up)
        XCTAssertEqual(session.peer, peer)
        XCTAssertEqual(session.handle(stop).state, idle)

        XCTAssertEqual(port.calls, [
            .subscribe(attempt.service, attempt.windows),
            .startDataSession(7, attempt.passphrase),
            .stopDataSession,
            .unsubscribe
        ])
        let lines = log.lines
        XCTAssertEqual(lines.count, 5, lines.joined(separator: "\n"))
        for line in lines {
            XCTAssertTrue(line.hasPrefix("nan: "), line)
            XCTAssertTrue(line.contains(" --"), line)
            XCTAssertTrue(line.contains("--> "), line)
            XCTAssertFalse(line.contains(attempt.passphrase), line)
            XCTAssertFalse(line.contains(ssi(0x11).hex), line)
            XCTAssertFalse(line.contains(peer.mac), line)
            XCTAssertFalse(line.contains(peer.linkLocal), line)
        }
    }

    func testAFailedSubscribeIsReportedAsNotReady() {
        let port = FakeNanPort()
        port.failure = .unavailable
        let session = NanSession(port: port, interface: "nan0")
        let step = session.handle(start)
        XCTAssertEqual(step.state, .blocked(.notReady))
        XCTAssertEqual(step.actions, [.unsubscribe, .failed(.notReady)])
        XCTAssertEqual(port.calls, [.subscribe(attempt.service, attempt.windows)])
    }

    func testAFailedDataSessionIsReportedAsNdpRefused() {
        let port = FakeNanPort()
        let session = NanSession(port: port, interface: "nan0")
        XCTAssertEqual(session.handle(start).state, subscribing)
        port.failure = .failed
        let step = session.handle(match)
        XCTAssertEqual(step.state, .blocked(.ndpRefused))
        XCTAssertEqual(step.actions, [.stopDataSession, .unsubscribe, .failed(.ndpRefused)])
    }

    func testStopFromIdleTouchesNothing() {
        let port = FakeNanPort()
        let session = NanSession(port: port, interface: "nan0")
        XCTAssertEqual(session.handle(stop), NanSessionStep(state: idle, actions: []))
        XCTAssertTrue(port.calls.isEmpty)
    }

    // MARK: fixtures

    private func ssi(_ byte: UInt8) -> NanSsi {
        NanSsi(Array(repeating: byte, count: 8))
    }
}

/// The port's test double: every call in order, with one injected failure.
private final class FakeNanPort: NanPort {
    enum Call: Equatable {
        case subscribe(String, [NanSsi])
        case updateWindows([NanSsi])
        case startDataSession(Int, String)
        case stopDataSession
        case unsubscribe
    }

    var calls: [Call] = []
    var failure: NanPortError?

    func subscribe(service: String, windows: [NanSsi]) throws {
        calls.append(.subscribe(service, windows))
        if let failure { throw failure }
    }

    func updateWindows(_ windows: [NanSsi]) throws {
        calls.append(.updateWindows(windows))
        if let failure { throw failure }
    }

    func startDataSession(token: Int, passphrase: String) throws {
        calls.append(.startDataSession(token, passphrase))
        if let failure { throw failure }
    }

    func stopDataSession() { calls.append(.stopDataSession) }

    func unsubscribe() { calls.append(.unsubscribe) }
}

private final class LogCapture {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
#endif
