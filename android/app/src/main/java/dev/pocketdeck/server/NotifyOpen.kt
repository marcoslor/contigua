package dev.pocketdeck.server

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import android.os.Bundle

/**
 * Sending a forwarded notification's own action on a display (docs/design/
 * notify.md). Pure enough to unit-test the options bundle: the shell server
 * owns the virtual display and holds START_ACTIVITIES_FROM_BACKGROUND, so the
 * send works while the phone's UI is in the background.
 */
object NotifyOpen {

    /** AOSP's ActivityOptions keys; the bundle is what `send` receives. */
    const val KEY_LAUNCH_DISPLAY_ID = "android.activity.launchDisplayId"

    /**
     * API 34 writes the "allowed" boolean for MODE_BACKGROUND_ACTIVITY_START_ALLOWED
     * (later platforms may carry the mode int as well).
     */
    const val KEY_PENDING_INTENT_BACKGROUND_ACTIVITY_ALLOWED =
        "android.pendingIntent.backgroundActivityAllowed"
    const val KEY_PENDING_INTENT_BACKGROUND_ACTIVITY_START_MODE =
        "android.pendingIntent.backgroundActivityStartMode"

    /** The options the send carries: the target display and the BAL mode. */
    fun options(displayId: Int): Bundle {
        val options = ActivityOptions.makeBasic()
        options.setLaunchDisplayId(displayId)
        if (Build.VERSION.SDK_INT >= 34) {
            options.setPendingIntentBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
            )
        }
        return options.toBundle()
    }

    /**
     * Sends [intent] on [displayId]; null when it went out, else the reason the
     * caller logs (`notify.open fallback reason=<reason>`). A non-activity
     * action (a service or broadcast) is not what a notification click means
     * here: the Mac window already shows the app, so the click just falls back.
     */
    fun send(context: Context, intent: PendingIntent, displayId: Int): String? {
        if (!intent.isActivity) return "NotActivity"
        return try {
            intent.send(context, 0, null, null, null, null, options(displayId))
            null
        } catch (e: PendingIntent.CanceledException) {
            e.javaClass.simpleName
        } catch (e: Exception) {
            e.javaClass.simpleName
        }
    }
}
