package dev.pocketdeck.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import dev.pocketdeck.R

/**
 * The ring side of `phone.ring` (docs/PROTOCOL.md "Ring"): the default alarm
 * sound at the phone's alarm volume, shown over the lock screen with a Stop
 * button, for at most 30 s. It runs in the app process because the shell
 * service cannot show UI or play audio; a broadcast from
 * [RingController.stop] silences it early.
 */
class RingActivity : Activity() {

    companion object {
        const val MAX_SECONDS = 30
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var audio: AudioManager
    private var player: MediaPlayer? = null
    private var focusRequest: AudioFocusRequest? = null

    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = stopRinging()
    }
    private val timeout = Runnable { stopRinging() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The person may have locked the phone since the Mac asked: the ring is
        // the one thing that must not wait for an unlock.
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        audio = getSystemService(AudioManager::class.java)
        setContentView(layout())
        ContextCompat.registerReceiver(this, stopReceiver,
            IntentFilter(RingController.ACTION_STOP), ContextCompat.RECEIVER_NOT_EXPORTED)
        startRinging(intent?.getIntExtra(RingController.EXTRA_SECONDS, MAX_SECONDS) ?: MAX_SECONDS)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        startRinging(intent.getIntExtra(RingController.EXTRA_SECONDS, MAX_SECONDS))
    }

    override fun onDestroy() {
        handler.removeCallbacks(timeout)
        runCatching { unregisterReceiver(stopReceiver) }
        stopSound()
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
            setOnClickListener { stopRinging() }
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = 48 })
    }

    private fun startRinging(rawSeconds: Int) {
        val seconds = rawSeconds.coerceIn(1, MAX_SECONDS)
        stopSound()
        // USAGE_ALARM routes to the alarm stream: the ring is as loud as the
        // person's alarms, and a silenced phone stays silent.
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener { change ->
                if (change <= AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stopRinging()
            }
            .build()
        audio.requestAudioFocus(request)
        focusRequest = request
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        if (uri == null) {
            stopRinging()
            return
        }
        val created = MediaPlayer()
        player = created
        created.setAudioAttributes(attributes)
        created.isLooping = true
        created.setOnPreparedListener { if (player === created) it.start() }
        created.setOnErrorListener { _, _, _ ->
            stopRinging()
            true
        }
        try {
            created.setDataSource(this, uri)
            created.prepareAsync()
        } catch (e: Exception) {
            stopRinging()
        }
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, seconds * 1000L)
    }

    private fun stopRinging() {
        handler.removeCallbacks(timeout)
        stopSound()
        RingController.cancelNotification(this)
        finishAndRemoveTask()
    }

    private fun stopSound() {
        player?.let {
            runCatching { if (it.isPlaying) it.stop() }
            runCatching { it.release() }
        }
        player = null
        focusRequest?.let { runCatching { audio.abandonAudioFocusRequest(it) } }
        focusRequest = null
    }
}
