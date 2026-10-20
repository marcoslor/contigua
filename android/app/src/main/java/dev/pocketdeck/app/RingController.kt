package dev.pocketdeck.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.pocketdeck.R

/**
 * A Mac's `phone.ring` (docs/PROTOCOL.md "Ring"). The shell service has no UI and
 * no audio of its own, so the session asks the app process.
 *
 * The sound is played here, from the app's foreground service, not by
 * [RingActivity]: a locked phone in a pocket is the case that matters, and there
 * Android may refuse to start an activity from the background, and full-screen
 * notifications are off by default for an app that is not an alarm clock. So
 * the alarm always sounds and the notification's Stop action always works; the
 * activity (a full-screen intent, plus a direct start for when the app is in
 * front) is only the big Stop button over the lock screen when the system
 * allows it.
 */
object RingController {
    const val ACTION_STOP = "dev.pocketdeck.app.RING_STOP"
    /** Sent when the ring ends for any reason, so [RingActivity] closes. */
    const val ACTION_ENDED = "dev.pocketdeck.app.RING_ENDED"
    const val MAX_SECONDS = 30
    const val NOTIFICATION_ID = 42
    private const val CHANNEL_ID = "ring"

    private val handler = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private var player: MediaPlayer? = null
    private var focusRequest: AudioFocusRequest? = null
    private var receiverRegistered = false
    private val timeout = Runnable { app?.let { stop(it) } }
    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) = stop(context)
    }

    /** Rings (or restarts the ring) for `seconds`, clamped to 1..30. */
    fun start(context: Context, seconds: Int) {
        handler.post { ring(context, seconds) }
    }

    private fun ring(context: Context, seconds: Int) {
        val bounded = seconds.coerceIn(1, MAX_SECONDS)
        val appContext = context.applicationContext
        app = appContext
        stopSound(appContext)
        if (!receiverRegistered) {
            ContextCompat.registerReceiver(appContext, stopReceiver,
                IntentFilter(ACTION_STOP), ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }
        playAlarm(appContext)
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, bounded * 1000L)
        val ring = Intent(appContext, RingActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        // Refused from the background on most locked phones; the full-screen
        // intent below is the system's own way in.
        runCatching { appContext.startActivity(ring) }
        notify(appContext, ring, bounded)
    }

    /** Silences a running ring; a no-op when nothing rings. */
    fun stop(context: Context) {
        handler.post { silence(context) }
    }

    private fun silence(context: Context) {
        val appContext = context.applicationContext
        handler.removeCallbacks(timeout)
        stopSound(appContext)
        NotificationManagerCompat.from(appContext).cancel(NOTIFICATION_ID)
        if (receiverRegistered) {
            runCatching { appContext.unregisterReceiver(stopReceiver) }
            receiverRegistered = false
        }
        appContext.sendBroadcast(Intent(ACTION_ENDED).setPackage(appContext.packageName))
    }

    private fun playAlarm(context: Context) {
        val audio = context.getSystemService(AudioManager::class.java) ?: return
        // USAGE_ALARM routes to the alarm stream: the ring is as loud as the
        // person's alarms.
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener { change ->
                // A call or another alarm takes over: stop rather than fight it.
                if (change <= AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stop(context)
            }
            .build()
        audio.requestAudioFocus(request)
        focusRequest = request
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ?: return
        val created = MediaPlayer()
        player = created
        created.setAudioAttributes(attributes)
        created.isLooping = true
        created.setOnPreparedListener { if (player === created) it.start() }
        created.setOnErrorListener { _, _, _ ->
            stop(context)
            true
        }
        try {
            created.setDataSource(context, uri)
            created.prepareAsync()
        } catch (e: Exception) {
            stop(context)
        }
    }

    private fun stopSound(context: Context) {
        player?.let {
            runCatching { if (it.isPlaying) it.stop() }
            runCatching { it.release() }
        }
        player = null
        val audio = context.getSystemService(AudioManager::class.java)
        focusRequest?.let { request -> runCatching { audio?.abandonAudioFocusRequest(request) } }
        focusRequest = null
    }

    private fun notify(context: Context, ring: Intent, seconds: Int) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Ringing",
                NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A Mac asked this phone to ring"
                setSound(null, null)
                enableVibration(false)
            })
        }
        val screen = PendingIntent.getActivity(context, 0, ring,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(context, 1,
            Intent(ACTION_STOP).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(context.getString(R.string.ring_title))
            .setContentText(context.getString(R.string.ring_body))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(screen)
            .setFullScreenIntent(screen, true)
            .setTimeoutAfter(seconds * 1000L)
            .addAction(0, context.getString(R.string.ring_stop), stop)
            .build()
        runCatching { manager.notify(NOTIFICATION_ID, notification) }
    }
}
