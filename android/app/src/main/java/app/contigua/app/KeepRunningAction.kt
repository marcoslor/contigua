package app.contigua.app

/**
 * The one "keep running in the background" action, behind both the onboarding
 * step and the home switch (docs/specs/phone-app.md PHONE-19). It used to live
 * only in the view model's onboarding button, which stored "asked once" and
 * threw the settings intent away inside `runCatching` — the reported "clicking
 * that does nothing".
 *
 * Each effect is injected so the rule is JVM-testable: the pref, the service
 * start and the exemption request happen in one order, and a request is made
 * only while the exemption is missing.
 */
class KeepRunningAction(
    private val isExempt: () -> Boolean,
    private val store: (Boolean) -> Unit,
    private val startService: () -> Unit,
    /** Asks for the exemption; true when a settings screen opened. */
    private val requestExemption: () -> Boolean,
    private val log: (String) -> Unit = {},
) {

    /** What the caller should say or do next. */
    enum class Result {
        /** The switch went off: the service lives with the app's task. */
        OFF,

        /** On, and Android already exempts Contigua. */
        ON_EXEMPT,

        /** On; the exemption screen opened for the person. */
        ON_ASKED,

        /** On, but no settings screen could open; the person needs the path. */
        ON_SETTINGS_UNAVAILABLE,
    }

    fun apply(on: Boolean): Result {
        store(on)
        if (!on) {
            log("keep running off")
            return Result.OFF
        }
        startService()
        if (isExempt()) {
            log("keep running on; already exempt")
            return Result.ON_EXEMPT
        }
        val opened = requestExemption()
        log(if (opened) "keep running on; exemption screen opened"
        else "keep running on; no battery settings screen opened")
        return if (opened) Result.ON_ASKED else Result.ON_SETTINGS_UNAVAILABLE
    }
}
