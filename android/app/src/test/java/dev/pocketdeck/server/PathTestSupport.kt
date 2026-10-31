package dev.pocketdeck.server

import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec

/**
 * Test-side path unwrapping: a v4 session sends its JSON and input frames
 * inside RELIABLE (docs/design/paths.md §5.5). Tests keep writing bare frames
 * (the receiver accepts an unknown bare frame; the product never sends one),
 * and read through this helper so an ACK never becomes a JSON parse error.
 */
internal fun readPathFrame(reader: FrameReader): Frame? {
    while (true) {
        val frame = reader.readFrame() ?: return null
        if (frame.type != PathCodec.TYPE_ACK) return frame
    }
}

internal fun pathJson(frame: Frame): Map<String, Any?> =
    if (frame.type == PathCodec.TYPE_RELIABLE) {
        Json.parseObject(String(PathCodec.decodeReliable(frame).inner.payload))
    } else {
        Json.parseObject(String(frame.payload))
    }
