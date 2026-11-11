package app.contigua.server

/**
 * WIN-61's display-refresh decision. `vd_rate` is off at 0 (or junk) and
 * otherwise asks for 60–120 Hz through `VirtualDisplayConfig.Builder`'s
 * `setRequestedRefreshRate`; the method's presence is injected so this stays
 * pure Kotlin and the JVM tests pin the missing-method fallback. The classic
 * `createVirtualDisplay` path has no rate and says so in a closed token.
 */
internal object DisplayRate {
    const val MIN_HZ = 60
    const val MAX_HZ = 120

    /** The requested refresh rate, or null when off or unsupported. */
    fun requested(vdRate: Int, builderHasMethod: Boolean): Float? {
        if (!builderHasMethod || vdRate <= 0) return null
        return clamp(vdRate).toFloat()
    }

    /** The strategy line's token for a request the builder cannot honour. */
    fun unsupported(vdRate: Int, builderHasMethod: Boolean): String? =
        if (vdRate > 0 && !builderHasMethod) "vd_rate=${clamp(vdRate)} unsupported" else null

    /** The classic path's line when a rate was requested but cannot be applied. */
    fun classicUnsupported(vdRate: Int): String? =
        if (vdRate > 0) "rate=${clamp(vdRate)} unsupported (classic)" else null

    /** The display line's token for an applied rate. */
    fun displayToken(rate: Float?): String? = rate?.let { "rate=${it.toInt()}" }

    private fun clamp(vdRate: Int): Int = vdRate.coerceIn(MIN_HZ, MAX_HZ)
}
