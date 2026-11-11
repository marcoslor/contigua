import XCTest
@testable import Contigua

/// WIN-63: an older phone forwards the encoder's per-frame statistics as a new
/// VIDEO_CONFIG with the same bytes before almost every frame. Only a real
/// change may flush the decoder and break the reference chain.
final class ConfigRepeatTests: XCTestCase {
    private let sets: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x1E, 0, 0, 0, 1, 0x68, 0xCE, 0x38, 0x80]

    private func config(width: UInt16 = 2136, height: UInt16 = 1482, sets: [UInt8]? = nil,
                        codec: UInt8 = VideoConfig.codecH264) -> VideoConfig {
        VideoConfig(codec: codec, width: width, height: height, parameterSets: sets ?? self.sets)
    }

    func testTheFirstConfigFlushes() {
        XCTAssertTrue(VideoLayerView.configNeedsFlush(applied: nil, next: config()))
    }

    func testARepeatedConfigKeepsTheDecoder() {
        XCTAssertFalse(VideoLayerView.configNeedsFlush(applied: config(), next: config()))
    }

    func testNewParameterSetsFlush() {
        var other = sets
        other[other.count - 2] = 0x3C
        XCTAssertTrue(VideoLayerView.configNeedsFlush(applied: config(), next: config(sets: other)))
    }

    func testANewSizeOrCodecFlushes() {
        XCTAssertTrue(VideoLayerView.configNeedsFlush(applied: config(), next: config(width: 1080)))
        XCTAssertTrue(VideoLayerView.configNeedsFlush(applied: config(), next: config(height: 1080)))
        XCTAssertTrue(VideoLayerView.configNeedsFlush(applied: config(),
                                                      next: config(codec: VideoConfig.codecHEVC)))
    }
}
