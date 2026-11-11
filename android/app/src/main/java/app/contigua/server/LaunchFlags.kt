package app.contigua.server

import android.content.Intent

/**
 * WIN-32: the Intent flags a window launch carries.
 *
 * One stream is one virtual display and one task. Without `newInstance` the
 * launch is today's: `FLAG_ACTIVITY_NEW_TASK`, and the platform may move the
 * app's one task onto the new display. With it, `FLAG_ACTIVITY_NEW_DOCUMENT`
 * with `FLAG_ACTIVITY_MULTIPLE_TASK` asks for another task of the same activity
 * — the app's own `launchMode`/`documentLaunchMode` still decides whether one
 * appears. Both paths ([AndroidLauncher]'s binder call and its `am start`
 * fallback) use this, so the two can never disagree.
 */
internal object LaunchFlags {

    /** The flags of one `window.open` launch. */
    fun of(newInstance: Boolean): Int = if (newInstance) {
        Intent.FLAG_ACTIVITY_NEW_TASK or
            Intent.FLAG_ACTIVITY_NEW_DOCUMENT or
            Intent.FLAG_ACTIVITY_MULTIPLE_TASK
    } else {
        Intent.FLAG_ACTIVITY_NEW_TASK
    }
}
