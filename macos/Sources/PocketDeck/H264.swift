// H.264 helpers: Annex-B splitting and conversion to AVCC (length-prefixed)
// for CMSampleBuffer creation. Pure byte work so it is unit-testable without
// AVFoundation.

import Foundation

enum H264NalType: UInt8 {
    case sliceNonIdr = 1
    case sliceIdr = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case aud = 9
}

enum AnnexB {
    /// Split an Annex-B byte stream into NAL units (start codes removed).
    /// Handles both 3-byte (00 00 01) and 4-byte (00 00 00 01) prefixes.
    static func units(_ data: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var start: Int?
        var i = 0
        while i < data.count {
            if i + 3 <= data.count, data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if let s = start, s < i { units.append(Array(data[s..<i])) }
                i += 3
                start = i
            } else if i + 4 <= data.count, data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                if let s = start, s < i { units.append(Array(data[s..<i])) }
                i += 4
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < data.count { units.append(Array(data[s...])) }
        return units.filter { !$0.isEmpty }
    }

    static func nalType(_ unit: [UInt8]) -> UInt8 {
        unit.first.map { $0 & 0x1F } ?? 0
    }

    /// Build an AVCC (4-byte big-endian length prefixed) access unit from NAL
    /// units. In-band parameter sets and access-unit delimiters are dropped:
    /// the decoder gets SPS/PPS from the format description built from
    /// VIDEO_CONFIG, and AUDs are not needed by AVSampleBufferDisplayLayer.
    static func avcc(from units: [[UInt8]], dropParameterSetsAndAUD: Bool = true) -> [UInt8] {
        var out = [UInt8]()
        for unit in units where !unit.isEmpty {
            if dropParameterSetsAndAUD {
                switch nalType(unit) {
                case H264NalType.sps.rawValue, H264NalType.pps.rawValue, H264NalType.aud.rawValue:
                    continue
                default:
                    break
                }
            }
            out.appendBE(UInt32(unit.count))
            out.append(contentsOf: unit)
        }
        return out
    }

    /// Annex-B bytes -> AVCC bytes, dropping SPS/PPS/AUD.
    static func avcc(fromAnnexB data: [UInt8]) -> [UInt8] {
        avcc(from: units(data))
    }

    /// Extract the SPS and PPS NAL units from Annex-B parameter-set bytes.
    static func parameterSets(from data: [UInt8]) -> (sps: [UInt8], pps: [UInt8])? {
        var sps: [UInt8]?
        var pps: [UInt8]?
        for unit in units(data) {
            switch nalType(unit) {
            case H264NalType.sps.rawValue: if sps == nil { sps = unit }
            case H264NalType.pps.rawValue: if pps == nil { pps = unit }
            default: break
            }
        }
        guard let s = sps, let p = pps else { return nil }
        return (s, p)
    }
}
