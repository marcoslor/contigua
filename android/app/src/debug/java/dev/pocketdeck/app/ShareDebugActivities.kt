package dev.pocketdeck.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.view.ContentInfoCompat
import androidx.core.view.OnReceiveContentListener
import androidx.core.view.ViewCompat

/**
 * Debug builds only (ISS-51): the two stand-ins a share target's screen is
 * reproduced with, no WhatsApp needed.
 *
 * [ShareDebugActivity] is a window's app with an image paste field. Its
 * listener starts [ShareDebugPickerActivity] from the *application* context
 * with `FLAG_ACTIVITY_NEW_TASK`, the way a share target's picker is started
 * from a non-activity context: with no calling activity the system gives the
 * new task the phone's own display, which is the bug.
 *
 * [ShareDebugSendActivity] is the same app's `ACTION_SEND` target for
 * `application/pdf` (a debug-only filter, so the main ShareActivity's image and
 * text filters are untouched). It starts one picker from the application
 * context (the failing path); the paste field starts the activity-context
 * control.
 *
 * Every line logs numbers and fixed state names only: no text, no file name.
 */
class ShareDebugActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val field = EditText(this).apply {
            hint = "image field"
            inputType = android.text.InputType.TYPE_CLASS_TEXT
        }
        ViewCompat.setOnReceiveContentListener(field, arrayOf("image/*"),
            OnReceiveContentListener { _, _: ContentInfoCompat ->
                Log.i(TAG, "paste received display=${displayId()} task=${getTaskId()}")
                // The bug's path: no calling activity, so the system picks the
                // display. The control: this activity's own context keeps the
                // window's display.
                startPicker("app", fromActivity = false)
                startPicker("activity", fromActivity = true)
                null
            })
        setContentView(FrameLayout(this).apply { addView(field) })
        field.requestFocus()
        Log.i(TAG, "paste window display=${displayId()} task=${getTaskId()}")
    }

    private fun startPicker(origin: String, fromActivity: Boolean) {
        val intent = Intent(this, ShareDebugPickerActivity::class.java)
            .putExtra(ShareDebugPickerActivity.EXTRA_ORIGIN, origin)
        if (fromActivity) {
            startActivity(intent)
        } else {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            applicationContext.startActivity(intent)
        }
    }
}

/** The debug share target: a drop of a pdf starts the pickers, then leaves. */
class ShareDebugSendActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "send received display=${displayId()} task=${getTaskId()}")
        // The bug's path: a share target with no calling activity.
        val app = Intent(this, ShareDebugPickerActivity::class.java)
            .putExtra(ShareDebugPickerActivity.EXTRA_ORIGIN, "app")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        applicationContext.startActivity(app)
        finish()
    }
}

/** The "share screen": logs where its task landed, lives briefly, leaves. */
class ShareDebugPickerActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val origin = intent.getStringExtra(EXTRA_ORIGIN) ?: "app"
        Log.i(TAG, "picker origin=$origin phase=create display=${displayId()} task=${getTaskId()}")
        setContentView(TextView(this).apply { text = "share picker" })
        // The policy moves the task a moment after it is created; the settled
        // line is the one the check judges.
        Handler(Looper.getMainLooper()).postDelayed({
            Log.i(TAG, "picker origin=$origin phase=settled display=${displayId()} task=${getTaskId()}")
        }, SETTLE_MS)
        Handler(Looper.getMainLooper()).postDelayed({ finish() }, LIFETIME_MS)
    }

    companion object {
        const val EXTRA_ORIGIN = "origin"
        private const val SETTLE_MS = 2_000L
        private const val LIFETIME_MS = 6_000L
    }
}

private const val TAG = "ShareDebug"

private fun Activity.displayId(): Int = display?.displayId ?: -1
