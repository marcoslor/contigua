// MCPToolHost's pure decisions (docs/design/mcp.md).

import XCTest
@testable import Contigua

final class MCPToolHostTests: XCTestCase {

    // [MCP-33]
    func testNoAppListYetIsNotReady() {
        XCTAssertThrowsError(try MCPToolHost.appsAnswer([])) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .notReady)
            XCTAssertEqual((error as? MCPToolError)?.message,
                           "The phone's app list has not arrived yet; try again in a few seconds.")
        }
        XCTAssertThrowsError(try MCPToolHost.chooseApp("Settings", in: [])) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .notReady)
        }
        let apps = [AppInfo(json: ["pkg": "com.android.settings", "label": "Settings"])!]
        XCTAssertEqual(try MCPToolHost.chooseApp("Settings", in: apps).pkg, "com.android.settings")
        let answer = try? MCPToolHost.appsAnswer(apps)
        XCTAssertEqual((answer?["apps"] as? [[String: String]])?.first?["package"], "com.android.settings")
    }

    // MARK: phone_status (plan T8)

    private final class TestClock {
        var now = ContinuousClock.now
    }

    private func input(phone: MCPStatusPhone?, foreground: FrontRead?,
                       apps: [AppInfo] = []) -> MCPStatusInput {
        MCPStatusInput(connected: phone != nil, name: phone == nil ? nil : "My phone",
                       battery: phone == nil ? nil : 81, charging: false, windows: 2, maxWindows: 4,
                       phone: phone, foreground: foreground, apps: apps)
    }

    // [MCP-31]
    func testStatusSaysWhatLockedMeans() throws {
        let now = ContinuousClock.now
        let phone = MCPStatusPhone(locked: true, screen: .off, lockSource: .keyguardListener,
                                   lockChangedAt: now - .seconds(360))
        let answer = MCPToolHost.statusAnswer(input(phone: phone, foreground: FrontRead.none), now: now)
        XCTAssertEqual(answer["locked"] as? Bool, true)
        XCTAssertEqual(answer["screen"] as? String, "off")
        XCTAssertEqual(answer["lockSource"] as? String, "keyguard_listener")
        XCTAssertEqual(answer["lockChangedAgoMs"] as? Int, 360000)
        XCTAssertEqual(answer["maxWindows"] as? Int, 4)
        XCTAssertEqual(answer["input"] as? String,
                       "App windows take input whether or not the phone is locked; the Phone Mirror shows the lock screen until the person unlocks it.")

        let none = MCPToolHost.statusAnswer(input(phone: nil, foreground: nil), now: now)
        XCTAssertTrue(none["locked"] is NSNull, "no phone: locked must be null, got \(String(describing: none["locked"]))")
        XCTAssertTrue(none["screen"] is NSNull, "no phone: screen must be null")
        XCTAssertTrue(none["foreground"] is NSNull)
        XCTAssertNil(none["foregroundError"])
        XCTAssertEqual(none["connected"] as? Bool, false)
    }

    // [MCP-32]
    @MainActor
    func testStatusNamesTheForegroundApp() async throws {
        let clock = TestClock()
        let gate = FrontReadGate(now: { clock.now })
        var sent: [Int] = []
        gate.send = { sent.append($0) }
        let browser = AppInfo(json: ["pkg": "org.example.browser", "label": "Browser"])!
        let phone = MCPStatusPhone(locked: false, screen: .on, lockSource: .initialRead,
                                   lockChangedAt: clock.now)

        // A package the app list knows: its label.
        let first = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 1, "one task.front per status call")
        gate.reply(seq: try XCTUnwrap(sent.last), pkg: "org.example.browser")
        let named = await first.value
        let answer = MCPToolHost.statusAnswer(input(phone: phone, foreground: named, apps: [browser]),
                                              now: clock.now)
        let foreground = try XCTUnwrap(answer["foreground"] as? [String: Any])
        XCTAssertEqual(foreground["package"] as? String, "org.example.browser")
        XCTAssertEqual(foreground["label"] as? String, "Browser")
        XCTAssertNil(answer["foregroundError"])

        // pkg: null → foreground null, no error.
        clock.now += .seconds(3)
        let second = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 2)
        gate.reply(seq: sent[1], pkg: nil)
        let nothing = MCPToolHost.statusAnswer(input(phone: phone, foreground: await second.value),
                                               now: clock.now)
        XCTAssertTrue(nothing["foreground"] is NSNull)
        XCTAssertNil(nothing["foregroundError"])

        // not_available → not_supported.
        clock.now += .seconds(3)
        let third = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 3)
        gate.unavailable()
        let refused = MCPToolHost.statusAnswer(input(phone: phone, foreground: await third.value),
                                               now: clock.now)
        XCTAssertTrue(refused["foreground"] is NSNull)
        XCTAssertEqual(refused["foregroundError"] as? String, "not_supported")

        // Silence → timeout at 1 s.
        clock.now += .seconds(3)
        let started = ContinuousClock.now
        let silent = await gate.read()
        let waited = ContinuousClock.now - started
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(silent, .timeout)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(900))
        XCTAssertLessThan(waited, .milliseconds(1600))
        let late = MCPToolHost.statusAnswer(input(phone: phone, foreground: silent), now: clock.now)
        XCTAssertTrue(late["foreground"] is NSNull)
        XCTAssertEqual(late["foregroundError"] as? String, "timeout")

        // The panel's card read 1 s earlier: no new task.front, its answer reused.
        clock.now += .seconds(3)
        XCTAssertTrue(gate.ask(), "the card's read goes out")
        XCTAssertEqual(sent.count, 5)
        gate.reply(seq: sent[4], pkg: "org.example.browser")
        clock.now += .seconds(1)
        let reused = await gate.read()
        XCTAssertEqual(sent.count, 5, "a status call 1 s after the card's read sent another task.front")
        XCTAssertEqual(reused, .pkg("org.example.browser"))
    }

    // [MCP-32]
    @MainActor
    func testTwoStatusCallsInTwoSecondsShareOneRead() async throws {
        let clock = TestClock()
        let gate = FrontReadGate(now: { clock.now })
        var sent: [Int] = []
        gate.send = { sent.append($0) }

        // Two calls while the read is out: one request, both answered.
        let a = Task { await gate.read() }
        let b = Task { await gate.read() }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(sent.count, 1)
        gate.reply(seq: sent[0], pkg: "org.example.browser")
        let first = await a.value
        let second = await b.value
        XCTAssertEqual(first, .pkg("org.example.browser"))
        XCTAssertEqual(second, .pkg("org.example.browser"))

        // A third call 1.9 s after the request reuses it; the panel's ask too.
        clock.now += .milliseconds(1900)
        let third = await gate.read()
        XCTAssertEqual(third, .pkg("org.example.browser"))
        XCTAssertFalse(gate.ask(), "the card asked again within 2 s of the status call")
        XCTAssertEqual(sent.count, 1)

        // 2 s after the request: a new one.
        clock.now += .milliseconds(100)
        let fourth = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 2)
        gate.reply(seq: sent[1], pkg: nil)
        let refreshed = await fourth.value
        XCTAssertEqual(refreshed, FrontRead.none)
    }
}
