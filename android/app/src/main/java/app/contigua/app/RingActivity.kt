package app.contigua.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import app.contigua.R

/**
 * The lock-screen face of `phone.ring` (docs/PROTOCOL.md "Ring"): one big Stop
 * button. [RingController] owns the sound and the timeout; this activity only
 * stops it and closes when the ring ends, so a phone that never shows it still
 * rings.
 */
class RingActivity : Activity() {

    private val endedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = finishAndRemoveTask()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The person may have locked the phone since the Mac asked.
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        setContentView(layout())
        ContextCompat.registerReceiver(this, endedReceiver,
            IntentFilter(RingController.ACTION_ENDED), ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(endedReceiver) }
        super.onDestroy()
    }

    /** Black, centered, one big Stop: readable over a lock screen at arm's length. */
    private fun layout(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setBackgroundColor(Color.BLACK)
        addView(TextView(this@RingActivity).apply {
            text = getString(R.string.ring_title)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            gravity = Gravity.CENTER
        })
        addView(Button(this@RingActivity).apply {
            text = getString(R.string.ring_stop)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setOnClickListener {
                RingController.stop(this@RingActivity)
                finishAndRemoveTask()
            }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = 48 })
    }
}
