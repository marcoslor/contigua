package dev.pocketdeck.server

/**
 * The stream codecs the phone can encode (ISS-40's C1). H.264 is the default;
 * HEVC is the bench arm's opt-in and only runs when the Mac says it can decode
 * it and the phone's encoder takes the size (docs/PROTOCOL.md "Video rules").
 */
enum class VideoCodec(val mime: String, val wire: Int, val token: String) {
    Avc("video/avc", 1, "avc"),
    Hevc("video/hevc", 2, "hevc"),
}
