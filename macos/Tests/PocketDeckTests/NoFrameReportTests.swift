// WIN-66 (ISS-10): the phone's no-frame episode and the two Mac lines it
// prints. The field is optional and every word on a line is a closed token, so
// a phone with an unknown value still cannot put free text in the log.

import XCTest
@testable import PocketDeck

final class NoFrameReportTests: XCTestCase {

    private func message(_ noFrame: [String: Any]?) -> PhoneStreamStats {
        var json: [String: Any] = ["stream": 7, "windowMs": 2_000, "frames": 0]
        if let noFrame { json["noFrame"] = noFrame }
        return PhoneStreamStats(json: json)
    }

    private func report(_ extra: [String: Any] = [:]) -> [String: Any] {
        var out: [String: Any] = [
            "ep": 41, "ms": 1_500, "phase": "draining", "display": "virtual",
            "task": "launched", "on": "doze", "keyguard": "showing",
            "doze": "idle", "screen": "off", "nudge": 2,
            "out": 0, "kf": 0, "bytes": 0,
        ]
        for (key, value) in extra { out[key] = value }
        return out
    }

    private func texts(_ lines: [NoFrameLine]) -> [String] {
        lines.map { $0.text(stream: 7) }
    }

    func testTheOpenEpisodePrintsTheDocumentedLine() {
        var window = StreamStatsWindow()
        XCTAssertEqual(texts(window.notePhoneStats(message(report()))), [
            "stream 7: no frame for 1.5s phase=draining display=virtual task=launched" +
                " on=doze keyguard=showing doze=idle screen=off nudge=2 out=0 kf=0 bytes=0",
        ])
    }

    func testTheEndedEpisodePrintsItsSecondLine() {
        var window = StreamStatsWindow()
        XCTAssertEqual(texts(window.notePhoneStats(message(report()))).count, 1)
        XCTAssertEqual(
            texts(window.notePhoneStats(message(report(["outcome": "late", "waitedMs": 2_600])))),
            ["stream 7: no frame ended outcome=late after 2600ms"],
        )
    }

    func testAnEndedEpisodeThatWasNeverOpenedPrintsBothLines() {
        var window = StreamStatsWindow()
        let lines = texts(window.notePhoneStats(message(report(["outcome": "closed", "waitedMs": 22_000]))))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "stream 7: no frame ended outcome=closed after 22000ms")
    }

    func testARepeatedEpisodeDoesNotPrintTwice() {
        var window = StreamStatsWindow()
        XCTAssertEqual(window.notePhoneStats(message(report())).count, 1)
        XCTAssertTrue(window.notePhoneStats(message(report())).isEmpty)
        XCTAssertEqual(
            window.notePhoneStats(message(report(["outcome": "closed", "waitedMs": 22_000]))).count,
            1,
        )
        XCTAssertTrue(
            window.notePhoneStats(message(report(["outcome": "closed", "waitedMs": 22_000]))).isEmpty,
        )
    }

    func testAnotherEpisodePrintsAgain() {
        var window = StreamStatsWindow()
        _ = window.notePhoneStats(message(report()))
        XCTAssertEqual(window.notePhoneStats(message(report(["ep": 42]))).count, 1)
    }

    func testAnUnknownTokenStaysInsideTheClosedSet() {
        var window = StreamStatsWindow()
        let lines = texts(window.notePhoneStats(message(report([
            "phase": "what the app drew", "doze": "window title", "display": "mirror-ish",
        ]))))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("phase=unknown"))
        XCTAssertTrue(lines[0].contains("doze=unknown"))
        XCTAssertTrue(lines[0].contains("display=unknown"))
        XCTAssertFalse(lines[0].contains("app drew"))
        XCTAssertFalse(lines[0].contains("window title"))
    }

    func testAReportWithoutItsIdsIsIgnored() {
        var window = StreamStatsWindow()
        XCTAssertTrue(window.notePhoneStats(message(["ep": 41])).isEmpty)
        XCTAssertTrue(window.notePhoneStats(message(["ms": 1_500])).isEmpty)
        XCTAssertTrue(window.notePhoneStats(message(nil)).isEmpty)
    }

    func testAStatsMessageWithoutTheFieldIsUnchanged() {
        let stats = message(nil)
        XCTAssertNil(stats.noFrame)
        XCTAssertEqual(stats.frames, 0)
        XCTAssertEqual(stats.windowMs, 2_000)
    }
}
