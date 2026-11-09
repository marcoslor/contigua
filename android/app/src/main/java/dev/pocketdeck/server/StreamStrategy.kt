package dev.pocketdeck.server

/**
 * The stream strategy switches (ISS-40), parsed once per stream configure from
 * the `debug.pocketdeck.stream.*` system properties. Every value defaults to
 * today's behaviour, so a phone with no properties set streams exactly as
 * before; a switch the codec cannot honour falls back and says so.
 *
 * Pure Kotlin (the property reader is injected), so the JVM tests pin every
 * default, clamp and fallback without a codec or a device.
 */
data class StreamStrategy(
    val overflow: Overflow = Overflow.Drop,
    val queueMs: Int = DEFAULT_QUEUE_MS,
    val rateControl: RateControl = RateControl.Vbr,
    val capKbps: Int = DEFAULT_CAP_KBPS,
    val bppMilli: Int = DEFAULT_BPP_MILLI,
    val intraRefreshFrames: Int = 0,
    val refine: Boolean = false,
    val trafficClass: Int = 0,
    /** The on-demand link stall: 0 is off, otherwise the pause length in ms. */
    val stallMs: Int = 0,
    val stallEveryMs: Int = DEFAULT_STALL_EVERY_MS,
    /** The arm's codec request: HEVC by default, `codec=avc` forces H.264. */
    val codec: VideoCodec = VideoCodec.Hevc,
    /** P1: the encoder's frame rate and operating-rate hint, 30–120. */
    val fps: Int = DEFAULT_FPS,
    /** P1: the virtual display's requested refresh rate; 0 is off. */
    val vdRate: Int = 0,
    /** P2: ask a supporting codec for low-latency mode. */
    val lowLatency: Boolean = false,
    /** P3: the media plane. `tcp` is the shipped default until P5. */
    val transport: Transport = Transport.Tcp,
    /**
     * Overrun arm A: the encoder's bitrate key is this many times the target
     * the sender believes (a VBR encoder that overshoots its target). 1 is
     * off; the product never sets it.
     */
    val overshoot: Int = 1,
) {

    enum class Overflow { Drop, Suspend }

    enum class RateControl { Vbr, Cbr }

    enum class Transport(val token: String) { Tcp("tcp"), Auto("auto"), Udp("udp") }

    val capBps: Int get() = capKbps * 1000

    /** The queue's byte budget: today's bytes scale with the duration budget. */
    fun queueBytes(baseBytes: Int = DEFAULT_QUEUE_BYTES): Int =
        (baseBytes.toLong() * queueMs / DEFAULT_QUEUE_MS).toInt()

    /** The queue's video-duration budget in µs. */
    fun queueDurationUs(baseUs: Long = DEFAULT_QUEUE_DURATION_US): Long =
        baseUs * queueMs / DEFAULT_QUEUE_MS

    /**
     * The computed target: bpp_milli/1000 bits per pixel per frame at 60 fps,
     * clamped to the 500 kbps floor and cap_kbps. At the defaults it is the
     * stream's original `w·h·60·120/1000` capped at 8 Mbps.
     */
    fun bitrateFor(w: Int, h: Int, minBps: Int = MIN_BITRATE, fps: Int = 60): Int {
        val bits = w.toLong() * h.toLong() * fps * bppMilli / 1000
        return bits.coerceIn(minBps.toLong(), capBps.toLong()).toInt()
    }

    val isDefault: Boolean get() = this == DEFAULT

    /**
     * The one configure log line's body: the switches that differ from today,
     * in a fixed order, or `default`. [applied] is what the codec accepted, so
     * a refused switch names its fallback in a closed token.
     */
    fun describe(applied: Applied = Applied()): String {
        val parts = ArrayList<String>()
        // The line prints what differs from the default: only a forced AVC.
        if (codec == VideoCodec.Avc) parts += "codec=avc"
        if (rateControl == RateControl.Cbr) {
            parts += if (applied.rateControl == RateControl.Cbr) "rc=cbr" else "rc=cbr unsupported"
        }
        if (capKbps != DEFAULT_CAP_KBPS) parts += "cap_kbps=$capKbps"
        if (bppMilli != DEFAULT_BPP_MILLI) parts += "bpp_milli=$bppMilli"
        if (intraRefreshFrames > 0) {
            parts += if (applied.intraRefreshFrames == intraRefreshFrames) {
                "ir=$intraRefreshFrames"
            } else {
                "ir=$intraRefreshFrames unsupported"
            }
        }
        if (fps != DEFAULT_FPS) parts += "fps=$fps"
        if (vdRate > 0) {
            parts += if (applied.vdRate) "vd_rate=$vdRate" else "vd_rate=$vdRate unsupported"
        }
        if (lowLatency) {
            parts += if (applied.lowLatency) "low_latency=on" else "low_latency=on unsupported"
        }
        if (transport != Transport.Tcp) parts += "transport=${transport.token}"
        if (queueMs != DEFAULT_QUEUE_MS) parts += "queue_ms=$queueMs"
        if (overflow == Overflow.Suspend) parts += "overflow=suspend"
        if (overshoot != DEFAULT_OVERSHOOT) parts += "overshoot=$overshoot"
        if (refine) parts += "refine=on"
        if (trafficClass != 0) parts += "tos=0x%02x".format(trafficClass)
        if (stallMs > 0) parts += "stall=$stallMs/$stallEveryMs"
        return if (parts.isEmpty()) "default" else parts.joinToString(" ")
    }

    /**
     * The writer's gate for this stream, or null when the stall is off. Only a
     * debug property reaches this; no product path sets a stall.
     */
    internal fun stallGate(stream: Int, startMs: Long, log: (String) -> Unit = {}): StallGate? =
        if (stallMs > 0) StallGate(stream, stallMs, stallEveryMs, startMs, log) else null

    /** What the codec accepted at configure; the requested values live above. */
    data class Applied(
        val rateControl: RateControl = RateControl.Vbr,
        val intraRefreshFrames: Int = 0,
        val codec: VideoCodec = VideoCodec.Avc,
        /** The builder's refresh-rate setter exists and was used. */
        val vdRate: Boolean = false,
        val lowLatency: Boolean = false,
    )

    companion object {
        const val PREFIX = "debug.pocketdeck.stream."
        const val DEFAULT_QUEUE_MS = 250
        const val DEFAULT_CAP_KBPS = 8000
        const val DEFAULT_BPP_MILLI = 120
        const val DEFAULT_QUEUE_BYTES = 256 * 1024
        const val DEFAULT_QUEUE_DURATION_US = 250_000L
        const val MIN_BITRATE = 500_000
        const val DEFAULT_STALL_EVERY_MS = 5_000
        const val DEFAULT_FPS = 60
        const val MIN_FPS = 30
        const val MAX_FPS = 120
        const val MIN_VD_RATE = 60
        const val MAX_VD_RATE = 120
        const val DEFAULT_OVERSHOOT = 1
        const val MAX_OVERSHOOT = 32

        val DEFAULT = StreamStrategy()

        /** Parses the raw values; a missing or junk value is today's. */
        fun parse(read: (String) -> String?): StreamStrategy {
            val raw = { key: String -> read(key)?.trim()?.takeIf { it.isNotEmpty() } }
            return StreamStrategy(
                overflow = when (raw("overflow")) {
                    "suspend" -> Overflow.Suspend
                    else -> Overflow.Drop
                },
                queueMs = raw("queue_ms").parseInt(DEFAULT_QUEUE_MS, 30..1000),
                rateControl = when (raw("rc")) {
                    "cbr" -> RateControl.Cbr
                    else -> RateControl.Vbr
                },
                capKbps = raw("cap_kbps").parseInt(DEFAULT_CAP_KBPS, 1000..100_000),
                bppMilli = raw("bpp_milli").parseInt(DEFAULT_BPP_MILLI, 50..500),
                intraRefreshFrames = raw("ir").parseIntraRefresh(),
                refine = raw("refine") == "on",
                trafficClass = raw("tos").parseInt(0, 0..255),
                stallMs = raw("stall_ms").parseStallMs(),
                stallEveryMs = raw("stall_every_ms")
                    .parseInt(DEFAULT_STALL_EVERY_MS, 1_000..30_000),
                codec = if (raw("codec") == VideoCodec.Avc.token) VideoCodec.Avc else VideoCodec.Hevc,
                fps = raw("fps").parseInt(DEFAULT_FPS, MIN_FPS..MAX_FPS),
                vdRate = raw("vd_rate").parseVdRate(),
                lowLatency = raw("low_latency") == "on",
                transport = when (raw("transport")) {
                    "auto" -> Transport.Auto
                    "udp" -> Transport.Udp
                    else -> Transport.Tcp
                },
                overshoot = raw("overshoot")
                    .parseInt(DEFAULT_OVERSHOOT, 1..MAX_OVERSHOOT),
            )
        }

        /** The live read: one system-property lookup per key, at configure. */
        fun read(): StreamStrategy = parse { key -> Hidden.systemProperty(PREFIX + key) }
    }
}

private fun String?.parseInt(fallback: Int, range: IntRange): Int {
    val value = this?.toIntOrNull() ?: return fallback
    return value.coerceIn(range.first, range.last)
}

/** `ir`: 0 is off; any other value is a frame count clamped to 10–600. */
private fun String?.parseIntraRefresh(): Int {
    val value = this?.toIntOrNull() ?: return 0
    if (value <= 0) return 0
    return value.coerceIn(10, 600)
}

/** `stall_ms`: 0 (and junk) is off; any other value clamps to 50–2000. */
private fun String?.parseStallMs(): Int {
    val value = this?.toIntOrNull() ?: return 0
    if (value <= 0) return 0
    return value.coerceIn(50, 2_000)
}

/** `vd_rate`: 0 (and junk) is off; any other value clamps to 60–120 Hz. */
private fun String?.parseVdRate(): Int {
    val value = this?.toIntOrNull() ?: return 0
    if (value <= 0) return 0
    return value.coerceIn(StreamStrategy.MIN_VD_RATE, StreamStrategy.MAX_VD_RATE)
}
