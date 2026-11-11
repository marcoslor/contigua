package app.contigua.server

/**
 * The stream codecs the phone can encode (ISS-40's C1). HEVC is the default
 * when the Mac says it decodes it in hardware and the phone has a hardware
 * encoder for the size; `codec=avc` forces H.264 (docs/PROTOCOL.md "Video
 * rules").
 */
enum class VideoCodec(val mime: String, val wire: Int, val token: String) {
    Avc("video/avc", 1, "avc"),
    Hevc("video/hevc", 2, "hevc"),
}
