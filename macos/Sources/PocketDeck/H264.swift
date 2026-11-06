// Annex-B helpers: splitting and conversion to AVCC (length-prefixed) for
// CMSampleBuffer creation. Pure byte work so it is unit-testable without
// AVFoundation. The type field is codec-specific: H.264's is `byte & 0x1F`,
// HEVC's `(byte >> 1) & 0x3F` (docs/PROTOCOL.md "Video rules").

import Foundation

enum H264NalType: UInt8 {
    case sliceNonIdr = 1
    case sliceIdr = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case aud = 9
}

enum HEVCNalType: UInt8 {
    case sliceIdrWRADL = 19
    case sliceIdrNLp = 20
    case cra = 21
    case vps = 32
    case sps = 33
    case pps = 34
    case aud = 35
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

    /// The NAL type in [unit]'s own codec's numbering.
    static func nalType(_ unit: [UInt8], codec: VideoCodec = .avc) -> UInt8 {
        guard let first = unit.first else { return 0 }
        switch codec {
        case .avc: return first & 0x1F
        case .hevc: return (first >> 1) & 0x3F
        }
    }

    /// True when these units hold an IDR slice a decoder can start on: AVC 5,
    /// HEVC 19 or 20. A HEVC CRA (21) is a key frame, not an IDR.
    static func isIdr(_ units: [[UInt8]], codec: VideoCodec) -> Bool {
        switch codec {
        case .avc:
            return units.contains { nalType($0, codec: .avc) == H264NalType.sliceIdr.rawValue }
        case .hevc:
            return units.contains {
                let type = nalType($0, codec: .hevc)
                return type == HEVCNalType.sliceIdrWRADL.rawValue
                    || type == HEVCNalType.sliceIdrNLp.rawValue
            }
        }
    }

    /// Build an AVCC (4-byte big-endian length prefixed) access unit from NAL
    /// units. In-band parameter sets and access-unit delimiters are dropped:
    /// the decoder gets them from the format description built from
    /// VIDEO_CONFIG, and AUDs are not needed by AVSampleBufferDisplayLayer.
    static func avcc(from units: [[UInt8]], codec: VideoCodec = .avc,
                     dropParameterSetsAndAUD: Bool = true) -> [UInt8] {
        var out = [UInt8]()
        for unit in units where !unit.isEmpty {
            if dropParameterSetsAndAUD {
                let type = nalType(unit, codec: codec)
                let drop: Bool
                switch codec {
                case .avc:
                    drop = type == H264NalType.sps.rawValue || type == H264NalType.pps.rawValue
                        || type == H264NalType.aud.rawValue
                case .hevc:
                    drop = type == HEVCNalType.vps.rawValue || type == HEVCNalType.sps.rawValue
                        || type == HEVCNalType.pps.rawValue || type == HEVCNalType.aud.rawValue
                }
                if drop { continue }
            }
            out.appendBE(UInt32(unit.count))
            out.append(contentsOf: unit)
        }
        return out
    }

    /// Annex-B bytes -> AVCC bytes, dropping the codec's parameter sets and AUD.
    static func avcc(fromAnnexB data: [UInt8], codec: VideoCodec = .avc) -> [UInt8] {
        avcc(from: units(data), codec: codec)
    }

    /// Extract the SPS and PPS NAL units from an AVC Annex-B parameter-set blob.
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

    /// Extract VPS, SPS and PPS from an HEVC Annex-B parameter-set blob.
    static func hevcParameterSets(from data: [UInt8]) -> (vps: [UInt8], sps: [UInt8], pps: [UInt8])? {
        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        for unit in units(data) {
            switch nalType(unit, codec: .hevc) {
            case HEVCNalType.vps.rawValue: if vps == nil { vps = unit }
            case HEVCNalType.sps.rawValue: if sps == nil { sps = unit }
            case HEVCNalType.pps.rawValue: if pps == nil { pps = unit }
            default: break
            }
        }
        guard let v = vps, let s = sps, let p = pps else { return nil }
        return (v, s, p)
    }
}
