package app.contigua.server

import android.content.pm.ActivityInfo

/**
 * WIN-24: can this app run a second instance of its launcher activity on
 * another virtual display?
 *
 * The platform decides instances from the launcher activity's `launchMode` and
 * `documentLaunchMode`; `PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI` is the
 * app's own claim that it is built for several windows. Both must agree — the
 * property alone is a claim ([AndroidLauncher] reads it), the modes alone would
 * enable every app on the phone (`.agent/multiwin/spike.md`). An allow-list
 * covers an app found to work without the property; empty today.
 *
 * Pure: the PackageManager reads live in [AndroidLauncher], so every
 * combination is a unit test.
 */
internal object MultiInstancePolicy {

    /** Apps known to work without the property. Empty until one is found. */
    val ALLOW_LIST: Set<String> = emptySet()

    /**
     * A second task can be created from `standard`, `singleTop` and
     * `singleInstancePerTask`; `singleTask` and `singleInstance` reuse their
     * one task whatever the launching Intent says.
     */
    private val ALLOWED_LAUNCH_MODES = setOf(
        ActivityInfo.LAUNCH_MULTIPLE,
        ActivityInfo.LAUNCH_SINGLE_TOP,
        ActivityInfo.LAUNCH_SINGLE_INSTANCE_PER_TASK,
    )

    fun multi(pkg: String, facts: LaunchFacts, allowList: Set<String> = ALLOW_LIST): Boolean {
        if (!ALLOWED_LAUNCH_MODES.contains(facts.launchMode)) return false
        if (facts.documentLaunchMode == ActivityInfo.DOCUMENT_LAUNCH_NEVER) return false
        if (facts.multiInstanceProperty) return true
        // An empty package would match a blank list entry and enable an app
        // that declares nothing.
        return pkg.isNotEmpty() && allowList.contains(pkg)
    }
}

/**
 * The launcher activity's declarations, as `PackageManager` reports them.
 *
 * @property multiInstanceProperty `PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI`
 *   for that activity; false below API 35, where the property does not exist.
 */
internal data class LaunchFacts(
    val launchMode: Int,
    val documentLaunchMode: Int,
    val multiInstanceProperty: Boolean,
)
