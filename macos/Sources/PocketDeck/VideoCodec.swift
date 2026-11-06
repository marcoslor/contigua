// The stream codecs the wire and the Mac's decoders speak (docs/PROTOCOL.md
// "Video rules"). H.264 is the default; HEVC is the bench arm's opt-in, sent
// only when this Mac says it decodes HEVC in hardware.

import CoreMedia
import VideoToolbox

enum VideoCodec: UInt8, Equatable {
    case avc = 1
    case hevc = 2

    /// The hello's name and the stats line's closed token.
    var token: String {
        switch self {
        case .avc: return "avc"
        case .hevc: return "hevc"
        }
    }

    var mediaSubtype: CMVideoCodecType {
        switch self {
        case .avc: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    static var hevcHardwareSupported: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    }

    /// What `hello.codecs` lists: AVC always, HEVC only with hardware decode.
    static func hardwareTokens(hevcSupported: Bool = hevcHardwareSupported) -> [String] {
        hevcSupported ? [VideoCodec.avc.token, VideoCodec.hevc.token] : [VideoCodec.avc.token]
    }
}

/// One VIDEO_CONFIG's answer: decode it with this codec, or refuse the stream.
enum CodecDecision: Equatable {
    case decode(VideoCodec)
    case refuse(token: String)
}

enum VideoCodecPolicy {
    /// A config's codec number against this Mac's decoders. An unknown number
    /// and HEVC without hardware decode are refusals, never a guess.
    static func decision(for codec: UInt8,
                         hevcHardware: Bool = VideoCodec.hevcHardwareSupported) -> CodecDecision {
        switch codec {
        case VideoCodec.avc.rawValue:
            return .decode(.avc)
        case VideoCodec.hevc.rawValue:
            return hevcHardware ? .decode(.hevc) : .refuse(token: VideoCodec.hevc.token)
        default:
            return .refuse(token: "unknown")
        }
    }
}
