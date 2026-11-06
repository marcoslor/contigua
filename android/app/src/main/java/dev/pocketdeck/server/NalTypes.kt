package dev.pocketdeck.server

import java.nio.ByteBuffer

/**
 * The NAL types at the front of an Annex-B access unit, up to and including
 * the first slice NAL. A key-flagged buffer may carry SPS/PPS/SEI and then a
 * non-IDR slice (intra refresh does this), so the type list is the only honest
 * answer to "is this frame an IDR?".
 *
 * The scan stops at the first slice because an access unit has one; a buffer
 * without a slice is truncated. [limit] bounds the bytes read, and the
 * buffer's position and limit are left untouched: the drain loop still has to
 * hand the same buffer to the socket.
 *
 * The type field is codec-specific (PROTOCOL "Video rules"): H.264's is
 * `byte & 0x1F`, HEVC's `(byte >> 1) & 0x3F`. HEVC's CRA (21) is a key frame
 * but not an IDR, so [isIdrAccessUnit] is what the counters ask.
 */
internal fun nalTypes(buffer: ByteBuffer, limit: Int, codec: VideoCodec = VideoCodec.Avc): List<Int> {
    val start = buffer.position()
    val end = minOf(buffer.limit(), start + limit.coerceAtLeast(0))
    return scanNalTypes(start, end, codec) { buffer.get(it).toInt() and 0xFF }
}

/**
 * The same scan over a byte array from [offset]. The send queue holds whole
 * wire frames, so it passes `Frames.VIDEO_FRAME_DATA_OFFSET`: the pts and flags
 * before the access unit can read as a start code (`00 00 01`).
 */
internal fun nalTypes(
    bytes: ByteArray,
    limit: Int = bytes.size,
    offset: Int = 0,
    codec: VideoCodec = VideoCodec.Avc,
): List<Int> {
    val start = offset.coerceIn(0, bytes.size)
    val end = minOf(bytes.size, start + limit.coerceAtLeast(0))
    return scanNalTypes(start, end, codec) { bytes[it].toInt() and 0xFF }
}

internal const val NAL_SLICE_NON_IDR = 1
internal const val NAL_SLICE_IDR = 5

internal const val HEVC_NAL_SLICE_IDR_W_RADL = 19
internal const val HEVC_NAL_SLICE_IDR_N_LP = 20

/** True when [types] hold a slice a decoder can start on (AVC 5; HEVC 19/20). */
internal fun isIdrAccessUnit(types: List<Int>, codec: VideoCodec): Boolean = when (codec) {
    VideoCodec.Avc -> types.contains(NAL_SLICE_IDR)
    VideoCodec.Hevc -> types.any {
        it == HEVC_NAL_SLICE_IDR_W_RADL || it == HEVC_NAL_SLICE_IDR_N_LP
    }
}

/** True when [type] is a slice (the scan's stop): AVC 1/5; HEVC 0–31. */
private fun isSlice(type: Int, codec: VideoCodec): Boolean = when (codec) {
    VideoCodec.Avc -> type == NAL_SLICE_NON_IDR || type == NAL_SLICE_IDR
    VideoCodec.Hevc -> type in 0..31
}

private fun nalTypeOf(header: Int, codec: VideoCodec): Int = when (codec) {
    VideoCodec.Avc -> header and 0x1F
    VideoCodec.Hevc -> (header shr 1) and 0x3F
}

private inline fun scanNalTypes(
    start: Int,
    end: Int,
    codec: VideoCodec,
    byteAt: (Int) -> Int,
): List<Int> {
    val types = ArrayList<Int>(4)
    var index = start
    while (index < end) {
        val code = startCodeLength(index, end, byteAt)
        if (code == 0) {
            index++
            continue
        }
        val header = index + code
        if (header >= end) break
        val type = nalTypeOf(byteAt(header), codec)
        types.add(type)
        if (isSlice(type, codec)) break
        index = header + 1
    }
    return types
}

/** 3 for `00 00 01`, 4 for `00 00 00 01`, 0 when no start code begins here. */
private inline fun startCodeLength(index: Int, end: Int, byteAt: (Int) -> Int): Int {
    if (index + 3 <= end &&
        byteAt(index) == 0 && byteAt(index + 1) == 0 && byteAt(index + 2) == 1
    ) {
        return 3
    }
    if (index + 4 <= end &&
        byteAt(index) == 0 && byteAt(index + 1) == 0 &&
        byteAt(index + 2) == 0 && byteAt(index + 3) == 1
    ) {
        return 4
    }
    return 0
}
