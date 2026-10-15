package dev.pocketdeck.server

/** Sizing for the phone-screen mirror: the stream keeps display 0's aspect. */
internal object MirrorFit {

    /**
     * The largest 16-aligned size inside [box] with [screen]'s aspect, never
     * larger than the screen itself (upscaling only costs bitrate).
     */
    fun fit(box: IntSize, screen: IntSize): IntSize {
        if (screen.w <= 0 || screen.h <= 0) return IntSize(floor16(box.w), floor16(box.h))
        val scale = minOf(box.w.toDouble() / screen.w, box.h.toDouble() / screen.h, 1.0)
        return IntSize(
            maxOf(EncoderSizes.ALIGN, floor16((screen.w * scale).toInt())),
            maxOf(EncoderSizes.ALIGN, floor16((screen.h * scale).toInt())),
        )
    }

    /** After a rotation the Mac's box is still the old shape; turn it with the screen. */
    fun turnBox(box: IntSize, screen: IntSize): IntSize {
        val boxPortrait = box.h >= box.w
        val screenPortrait = screen.h >= screen.w
        return if (boxPortrait == screenPortrait) box else IntSize(box.h, box.w)
    }

    private fun floor16(v: Int): Int = if (v <= 0) 0 else (v / 16) * 16
}
