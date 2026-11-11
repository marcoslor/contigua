// HEVC's own path (ISS-40 C1): the NAL types, the format description from
// VPS/SPS/PPS, and one real VideoToolbox round trip. The round trip encodes
// here, in the test, so the receive path is proved on the bytes the platform
// actually makes — no fixture files.

import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import Contigua

final class HEVCTests: XCTestCase {
    private let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01, 0xFF]
    private let sps: [UInt8] = [0x42, 0x01, 0x01, 0x01]
    private let pps: [UInt8] = [0x44, 0x01, 0xC0]
    private let idr: [UInt8] = [0x26, 0x01, 0xAF]
    private let cra: [UInt8] = [0x2A, 0x01, 0xAF]
    private let delta: [UInt8] = [0x02, 0x01, 0xD0]

    private func annexB(_ units: [[UInt8]], fourByte: Bool = true) -> [UInt8] {
        var out: [UInt8] = []
        for unit in units {
            out += fourByte ? [0, 0, 0, 1] : [0, 0, 1]
            out += unit
        }
        return out
    }

    func testTheHevcNalTypesAreTheCodecsOwn() {
        XCTAssertEqual(AnnexB.nalType(vps, codec: .hevc), 32)
        XCTAssertEqual(AnnexB.nalType(sps, codec: .hevc), 33)
        XCTAssertEqual(AnnexB.nalType(pps, codec: .hevc), 34)
        XCTAssertEqual(AnnexB.nalType(idr, codec: .hevc), 19)
        XCTAssertEqual(AnnexB.nalType(cra, codec: .hevc), 21)
        XCTAssertEqual(AnnexB.nalType(delta, codec: .hevc), 1)
        // The AVC reading of the same bytes is a different number.
        XCTAssertEqual(AnnexB.nalType(sps), 2)
    }

    func testAnIdrIs19Or20AndACraIsNot() {
        XCTAssertTrue(AnnexB.isIdr([vps, sps, pps, idr], codec: .hevc))
        XCTAssertTrue(AnnexB.isIdr([[0x28, 0x01]], codec: .hevc), "IDR_N_LP is 20")
        XCTAssertFalse(AnnexB.isIdr([vps, sps, pps, cra], codec: .hevc),
                       "a CRA is a key frame, not an IDR")
        XCTAssertFalse(AnnexB.isIdr([vps, sps, pps, delta], codec: .hevc))
    }

    func testBothStartCodeWidthsAndTheTrailingSlice() {
        var stream: [UInt8] = [0, 0, 1] + vps
        stream += [0, 0, 0, 1] + sps
        stream += [0, 0, 1] + pps
        stream += [0, 0, 0, 1] + idr
        let units = AnnexB.units(stream)
        XCTAssertEqual(units.count, 4)
        XCTAssertEqual(units.map { AnnexB.nalType($0, codec: .hevc) }, [32, 33, 34, 19])
    }

    func testTheHevcParameterSetsComeOutOfTheConfig() throws {
        let bytes = annexB([vps, sps, pps])
        let sets = try XCTUnwrap(AnnexB.hevcParameterSets(from: bytes))
        XCTAssertEqual(sets.vps, vps)
        XCTAssertEqual(sets.sps, sps)
        XCTAssertEqual(sets.pps, pps)
        XCTAssertNil(AnnexB.hevcParameterSets(from: annexB([vps, sps])),
                     "a config needs all three")
        XCTAssertNil(AnnexB.parameterSets(from: bytes), "the AVC extractor does not read HEVC")
    }

    func testAVCCDropsTheHevcParameterSetsAndAUD() {
        let aud: [UInt8] = [0x46, 0x01, 0x50] // HEVC access unit delimiter, 35
        let avcc = AnnexB.avcc(from: [aud, vps, sps, pps, idr], codec: .hevc)
        var expected: [UInt8] = []
        expected.appendBE(UInt32(idr.count))
        expected += idr
        XCTAssertEqual(avcc, expected)
    }

    // MARK: The real round trip

    private func makePixelBuffer(width: Int, height: Int, seed: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attrs, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = y.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<width {
                    base[row * stride + column] = UInt8((column + row + Int(seed) * 7) & 0xFF)
                }
            }
        }
        if let cbcr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let base = cbcr.assumingMemoryBound(to: UInt8.self)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                    base[row * stride + column] = 128
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func annexB(fromAVCC sample: CMSampleBuffer) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        var index = 0
        while index + 4 <= length {
            let size = (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16)
                | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
            index += 4
            guard size > 0, index + size <= length else { return nil }
            out += [0, 0, 0, 1]
            out += Array(UnsafeBufferPointer(start: bytes + index, count: size))
            index += size
        }
        return out
    }

    private func hevcParameterSet(_ format: CMVideoFormatDescription,
                                  index: Int) -> [UInt8]? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer, size > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: size))
    }

    func testTheVideoToolboxRoundTripDecodesHEVC() throws {
        let width = 320
        let height = 240
        var encoder: VTCompressionSession?
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder)
        try XCTSkipUnless(created == noErr, "this Mac has no HEVC encoder")
        let compression = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(compression) }

        let lock = NSLock()
        var samples: [CMSampleBuffer] = []
        for index in 0..<4 {
            let buffer = try XCTUnwrap(makePixelBuffer(width: width, height: height,
                                                       seed: UInt8(index)))
            let status = VTCompressionSessionEncodeFrame(
                compression, imageBuffer: buffer,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample else { return }
                lock.lock()
                samples.append(sample)
                lock.unlock()
            }
            XCTAssertEqual(status, noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid),
                       noErr)
        lock.lock()
        let encoded = samples
        lock.unlock()
        XCTAssertEqual(encoded.count, 4, "four encoded HEVC samples")

        let sourceFormat = try XCTUnwrap(encoded.first.flatMap(CMSampleBufferGetFormatDescription))
        let vps = try XCTUnwrap(hevcParameterSet(sourceFormat, index: 0))
        let sps = try XCTUnwrap(hevcParameterSet(sourceFormat, index: 1))
        let pps = try XCTUnwrap(hevcParameterSet(sourceFormat, index: 2))
        var configBytes: [UInt8] = []
        for set in [vps, sps, pps] { configBytes += [0, 0, 0, 1] + set }
        let config = VideoConfig(codec: VideoConfig.codecHEVC, width: UInt16(width),
                                 height: UInt16(height), parameterSets: configBytes)

        // The receive path's own pieces: the format description from the
        // config, then each Annex-B access unit through the sample builder.
        let format = try XCTUnwrap(VideoLayerView.makeFormatDescription(config))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, Int32(width))
        var decoder: VTDecompressionSession?
        let decoderStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &decoder)
        XCTAssertEqual(decoderStatus, noErr)
        let decompression = try XCTUnwrap(decoder)
        defer { VTDecompressionSessionInvalidate(decompression) }

        var decoded = 0
        var built: [CMSampleBuffer] = []
        for (index, sample) in encoded.enumerated() {
            let accessUnit = try XCTUnwrap(annexB(fromAVCC: sample))
            let units = AnnexB.units(accessUnit)
            // Every unit of this key frame is kept; the builder only drops the
            // parameter sets and AUDs a decoder gets from the format description.
            let avcc = AnnexB.avcc(from: units, codec: .hevc)
            let input = try XCTUnwrap(VideoLayerView.makeSampleBuffer(
                avcc: avcc, format: format, ptsUs: UInt64(index)))
            built.append(input)
            let status = VTDecompressionSessionDecodeFrame(
                decompression, sampleBuffer: input, flags: [], infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                if status == noErr, imageBuffer != nil { decoded += 1 }
            }
            XCTAssertEqual(status, noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decompression)
        XCTAssertEqual(decoded, encoded.count, "every encoded frame decoded")

        // Live Text's own route, KeyframeSnapshotter, takes its decoder from
        // the format description: the same frames must give it a picture.
        let snapshotter = KeyframeSnapshotter()
        let snapshot = expectation(description: "snapshot")
        var snapshotBuffer: CVPixelBuffer?
        snapshotter.begin(format: format) { buffer in
            snapshotBuffer = buffer
            snapshot.fulfill()
        }
        for sample in built { snapshotter.feed(sample) }
        wait(for: [snapshot], timeout: 3)
        XCTAssertNotNil(snapshotBuffer, "KeyframeSnapshotter decoded the HEVC keyframe")
        snapshotter.cancel()
    }
}
