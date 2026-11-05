// The Mac's stream-strategy switches (ISS-40): the three keys, their defaults,
// junk rejection, the one-line-per-window text, and the default path staying
// today's (backing pixels, DisplayImmediately).

import AVFoundation
import XCTest
@testable import PocketDeck

final class MacStreamStrategyTests: XCTestCase {
    // MARK: Reading the keys

    func testNothingSetGivesTodaysValues() {
        let strategy = MacStreamStrategy.read { _ in nil }
        XCTAssertEqual(strategy.present, .immediate)
        XCTAssertEqual(strategy.pixels, .backing)
        XCTAssertEqual(strategy.net, .default)
        XCTAssertTrue(strategy.isDefault)
    }

    func testEachKeyParses() {
        let strategy = MacStreamStrategy.read { key in
            switch key {
            case MacStreamStrategy.presentKey: return "paced"
            case MacStreamStrategy.pixelsKey: return "panel"
            case MacStreamStrategy.netKey: return "video"
            default: return nil
            }
        }
        XCTAssertEqual(strategy.present, .paced)
        XCTAssertEqual(strategy.pixels, .panel)
        XCTAssertEqual(strategy.net, .video)
        XCTAssertFalse(strategy.isDefault)
    }

    func testJunkFallsBackToTheDefaultForItsKey() {
        let strategy = MacStreamStrategy.read { key in
            switch key {
            case MacStreamStrategy.presentKey: return "Paced"
            case MacStreamStrategy.pixelsKey: return "1"
            case MacStreamStrategy.netKey: return ""
            default: return nil
            }
        }
        XCTAssertEqual(strategy, MacStreamStrategy(), "closed tokens only; junk is today's value")
    }

    func testANonStringValueIsNilFromTheDefaultsReader() {
        let strategy = MacStreamStrategy.read { key in
            // UserDefaults returns an NSNumber for `defaults write … -int 1`;
            // the reader sees a non-string and keeps today's value.
            key == MacStreamStrategy.presentKey ? 1 : nil
        }
        XCTAssertEqual(strategy, MacStreamStrategy())
    }

    func testTheDefaultsReaderUsesTheSameKeys() {
        let stored = ["stream.present": "paced",
                      "stream.pixels": "panel",
                      "stream.net": "video"]
        let strategy = MacStreamStrategy.read { stored[$0] }
        XCTAssertEqual(strategy.present, .paced)
        XCTAssertEqual(strategy.pixels, .panel)
        XCTAssertEqual(strategy.net, .video)
    }

    // MARK: The log line

    func testTheDefaultLineIsTheClosedDefaultToken() {
        XCTAssertEqual(MacStreamStrategy().windowLine(stream: 3),
                       "stream 3 mac strategy: default")
    }

    func testTheLineCarriesAllThreeClosedTokens() {
        let strategy = MacStreamStrategy(present: .paced, pixels: .panel, net: .video)
        XCTAssertEqual(strategy.windowLine(stream: 12),
                       "stream 12 mac strategy: present=paced pixels=panel net=video")
    }

    func testOneSetKeyStillShowsTheOtherDefaults() {
        let strategy = MacStreamStrategy(present: .paced)
        XCTAssertEqual(strategy.windowLine(stream: 1),
                       "stream 1 mac strategy: present=paced pixels=backing net=default")
    }

    // MARK: The default path is today's

    func testTheDefaultStrategyAsksForTheWindowsBackingPixels() {
        let modern = EncoderSpec(widthAlign: 2, heightAlign: 2, maxWidth: 8192,
                                 maxHeight: 8192, maxPixelsAt60: 8192 * 8192)
        let size = VideoSize.displayPixels(bounds: CGSize(width: 1203, height: 693),
                                           backingScale: 2, encoder: modern,
                                           panelFactor: MacStreamStrategy().pixels == .backing ? 1 : 0.5)
        XCTAssertEqual(size.width, 2406)
        XCTAssertEqual(size.height, 1386)
    }

    func testTheDefaultSamplesAreMarkedDisplayImmediately() {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                      codecType: kCMVideoCodecType_H264,
                                                      width: 16, height: 16, extensions: nil,
                                                      formatDescriptionOut: &format), noErr)
        guard let format = format else { return XCTFail("no format description") }
        let avcc: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        guard let sample = VideoLayerView.makeSampleBuffer(avcc: avcc, format: format, ptsUs: 1) else {
            return XCTFail("no sample buffer")
        }
        XCTAssertTrue(VideoLayerView.carriesDisplayImmediately(sample))
    }
}
