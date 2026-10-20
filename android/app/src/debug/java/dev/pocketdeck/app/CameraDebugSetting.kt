package dev.pocketdeck.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug builds only: flips "Let Macs use the camera" from adb, through the same
 * calls the settings toggle makes after the runtime CAMERA dialog answered
 * ([Prefs.setCameraAllowed] and [CameraGate.push]). It exists because rewriting
 * `shared_prefs` behind the app's back races it: the notification listener
 * restarts the app around 260 ms after a force-stop, so the reloaded process can
 * write the old value back (docs/design/camera.md C1).
 *
 * ```
 * adb shell am broadcast -a dev.pocketdeck.DEBUG_CAMERA_SETTING --es state on
 * adb shell am broadcast -a dev.pocketdeck.DEBUG_CAMERA_SETTING --es state off
 * ```
 *
 * It never grants the permission itself: the rig does that with `pm grant`,
 * exactly as the person's dialog would. DUMP keeps ordinary apps out (see
 * AndroidManifest in src/debug).
 */
class CameraDebugSetting : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SET) return
        val raw = intent.getStringExtra(EXTRA_STATE)
        val want = CameraDebugArgs.parse(raw) ?: run {
            Log.i(TAG, "ignored: state=${raw ?: "-"}")
            return
        }
        Prefs.setCameraAllowed(context, want)
        if (!want) {
            // The toggle's off path also ends a live capture (fail closed).
            runCatching { context.stopService(Intent(context, CameraCaptureService::class.java)) }
        }
        CameraGate.push(context)
        Log.i(TAG, "camera setting on=$want (debug)")
    }

    companion object {
        const val ACTION_SET = "dev.pocketdeck.DEBUG_CAMERA_SETTING"
        const val EXTRA_STATE = "state"
        const val TAG = "PdCameraDebug"
    }
}

/**
 * The receiver's one argument: `on` or `off`, nothing else. Strict on purpose,
 * so a typo in a rig command cannot silently change a privacy setting; kept
 * free of Android types for CameraDebugArgsTest.
 */
internal object CameraDebugArgs {

    const val ON = "on"
    const val OFF = "off"

    /** @return the value to store, or null when [raw] is missing or not one of the two. */
    fun parse(raw: String?): Boolean? = when (raw?.trim()?.lowercase()) {
        ON -> true
        OFF -> false
        else -> null
    }
}
