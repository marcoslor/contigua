import XCTest
@testable import Contigua

final class H264Tests: XCTestCase {
    private let sps: [UInt8] = [0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80]
    private let pps: [UInt8] = [0x68, 0xCE, 0x38, 0x80]
    private let aud: [UInt8] = [0x09, 0xF0]
    private let idrSlice: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x01]
    private let deltaSlice: [UInt8] = [0x41, 0x9A, 0x02]

    private func annexB(_ units: [[UInt8]], fourByte: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        for unit in units {
            out += fourByte ? [0, 0, 0, 1] : [0, 0, 1]
            out += unit
        }
        return out
    }

    func testAnnexBUnitsSplit() {
        let stream = annexB([sps, pps, idrSlice])
        let units = AnnexB.units(stream)
        XCTAssertEqual(units, [sps, pps, idrSlice])
    }

    func testAnnexBUnitsSplitThreeByteStartCodes() {
        let stream = annexB([sps, pps, idrSlice], fourByte: false)
        XCTAssertEqual(AnnexB.units(stream), [sps, pps, idrSlice])
    }

    func testAnnexBUnitsMixedStartCodes() {
        var stream: [UInt8] = [0, 0, 1] + sps
        stream += [0, 0, 0, 1] + pps
        stream += [0, 0, 1] + deltaSlice
        XCTAssertEqual(AnnexB.units(stream), [sps, pps, deltaSlice])
    }

    func testSPSPPSExtraction() {
        let sets = AnnexB.parameterSets(from: annexB([aud, sps, pps]))
        XCTAssertEqual(sets?.sps, sps)
        XCTAssertEqual(sets?.pps, pps)
    }

    func testSPSPPSExtractionFailsWithoutBoth() {
        XCTAssertNil(AnnexB.parameterSets(from: annexB([sps])))
        XCTAssertNil(AnnexB.parameterSets(from: annexB([pps])))
        XCTAssertNil(AnnexB.parameterSets(from: annexB([aud, idrSlice])))
    }

    func testAnnexBToAVCCDropsParameterSetsAndAUD() {
        let avcc = AnnexB.avcc(fromAnnexB: annexB([aud, sps, pps, idrSlice]))
        var expected: [UInt8] = []
        expected.appendBE(UInt32(idrSlice.count))
        expected += idrSlice
        XCTAssertEqual(avcc, expected)
    }

    func testAnnexBToAVCCLengthPrefixesEveryNAL() {
        let avcc = AnnexB.avcc(fromAnnexB: annexB([idrSlice, deltaSlice]))
        var expected: [UInt8] = []
        expected.appendBE(UInt32(idrSlice.count)); expected += idrSlice
        expected.appendBE(UInt32(deltaSlice.count)); expected += deltaSlice
        XCTAssertEqual(avcc, expected)
        XCTAssertEqual(Array(avcc[0..<4]), [0x00, 0x00, 0x00, 0x05])
    }

    func testAnnexBToAVCCEmptyWhenOnlyParameterSets() {
        XCTAssertTrue(AnnexB.avcc(fromAnnexB: annexB([aud, sps, pps])).isEmpty)
    }

    func testNALTypeDetection() {
        XCTAssertEqual(AnnexB.nalType(sps), H264NalType.sps.rawValue)
        XCTAssertEqual(AnnexB.nalType(pps), H264NalType.pps.rawValue)
        XCTAssertEqual(AnnexB.nalType(aud), H264NalType.aud.rawValue)
        XCTAssertEqual(AnnexB.nalType(idrSlice), H264NalType.sliceIdr.rawValue)
        XCTAssertEqual(AnnexB.nalType(deltaSlice), H264NalType.sliceNonIdr.rawValue)
    }
}
