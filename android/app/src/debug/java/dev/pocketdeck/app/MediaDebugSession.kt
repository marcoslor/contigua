package dev.pocketdeck.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Debug builds only: one or two fake media sessions, driven from adb, so the
 * emulator can exercise artwork, seeking, session choice and volume without a
 * third-party app and without any person's content (docs/design/notify.md
 * "Media part 2"). Metadata and artwork are generated test values.
 *
 * ```
 * adb shell am broadcast -n dev.pocketdeck/dev.pocketdeck.app.MediaDebugTrigger \
 *     -a dev.pocketdeck.DEBUG_MEDIA --es op start --ei index 1
 * ```
 *
 * The component is named because an implicit broadcast is dropped while the app
 * sits in the background (Android 8+ receiver rule).
 *
 * It records what it receives — the seek position, the volume level, its
 * maximum — in logcat under a fixed tag; no title, artist, album or picture
 * byte ever reaches a log.
 */
class MediaDebugTrigger : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) {
            // A broadcast to this component without the action is ignored (the
            // rig sends both); say so instead of looking like a dead session.
            Log.i(TAG, "ignored: action=${intent.action}")
            return
        }
        // The sender gate is the receiver's android:permission="DUMP" in the
        // debug manifest: the system checks the sender (adb shell holds DUMP).
        // A runtime check cannot work here — onReceive runs outside a binder
        // call, so checkCallingOrSelfPermission only sees this app, which never
        // holds DUMP, and every broadcast would be refused.
        val args = MediaDebugArgs.parse(
            intent.getStringExtra("op"),
            if (intent.hasExtra("index")) intent.getIntExtra("index", 0) else null,
            intent.getBooleanExtra("paused", false),
        ) ?: run {
            Log.i(TAG, "ignored: bad arguments")
            return
        }
        if (args.start) MediaDebugSessions.start(context, args) else MediaDebugSessions.stop(args.index)
    }

    companion object {
        const val ACTION = "dev.pocketdeck.DEBUG_MEDIA"
        const val TAG = "PdMediaDebug"
    }
}

/** The fake sessions themselves: one per slot, replaced when started again. */
object MediaDebugSessions {

    private val sessions = HashMap<Int, FakeSession>()

    fun start(context: Context, args: MediaDebugArgs) {
        val slot = args.index ?: return
        stop(slot)
        sessions[slot] = FakeSession(context.applicationContext, slot, args.paused)
        Log.i(MediaDebugTrigger.TAG, "start slot=$slot paused=${if (args.paused) 1 else 0}")
    }

    /** Null stops every fake session. */
    fun stop(slot: Int?) {
        val targets = if (slot == null) sessions.keys.toList() else listOf(slot)
        for (index in targets) {
            sessions.remove(index)?.release()
            Log.i(MediaDebugTrigger.TAG, "stop slot=$index")
        }
    }
}

/**
 * One fake session: playing metadata with generated artwork, `ACTION_SEEK_TO`,
 * skip controls and an absolute volume provider (0..15) so the volume command
 * is observable without touching the emulator's own stream.
 */
private class FakeSession(context: Context, private val slot: Int, paused: Boolean) {

    private val basePositionMs = 10_000L
    private var anchorMs = SystemClock.elapsedRealtime()
    private var anchorPositionMs = basePositionMs
    private var playing = !paused
    private var volume = 8

    private val volumeProvider = object : VolumeProvider(VOLUME_CONTROL_ABSOLUTE, MAX_VOLUME, volume) {
        override fun onSetVolumeTo(newVolume: Int) {
            volume = newVolume.coerceIn(0, MAX_VOLUME)
            currentVolume = volume
            Log.i(MediaDebugTrigger.TAG, "volume level=$volume max=$MAX_VOLUME")
        }

        override fun onAdjustVolume(direction: Int) {
            onSetVolumeTo(volume + direction.coerceIn(-2, 2))
        }
    }

    /** Declared before the session uses it; its bodies run only after init. */
    private val callback: MediaSession.Callback by lazy {
        object : MediaSession.Callback() {
            override fun onPlay() = setPlaying(true)
            override fun onPause() = setPlaying(false)
            override fun onStop() = setPlaying(false)

            override fun onSeekTo(pos: Long) {
                anchorPositionMs = pos.coerceIn(0, DURATION_MS)
                anchorMs = SystemClock.elapsedRealtime()
                Log.i(MediaDebugTrigger.TAG, "seek positionMs=$anchorPositionMs")
                session.setPlaybackState(stateAt(anchorPositionMs))
            }

            override fun onSkipToNext() = onSeekTo(positionMs() + SKIP_MS)
            override fun onSkipToPrevious() = onSeekTo(positionMs() - SKIP_MS)
        }
    }

    val session: MediaSession = MediaSession(context, "pd-fake-$slot").apply {
        setPlaybackToRemote(volumeProvider)
        setCallback(callback, MediaDebugSessionsHandler.handler)
        setMetadata(metadata())
        setPlaybackState(stateAt(positionMs()))
        isActive = true
    }

    private val ticker = object : Runnable {
        override fun run() {
            if (!playing) return
            session.setPlaybackState(stateAt(positionMs()))
            MediaDebugSessionsHandler.handler.postDelayed(this, 1000)
        }
    }

    init {
        if (playing) MediaDebugSessionsHandler.handler.postDelayed(ticker, 1000)
    }

    private fun setPlaying(on: Boolean) {
        playing = on
        anchorMs = SystemClock.elapsedRealtime()
        anchorPositionMs = positionMs()
        MediaDebugSessionsHandler.handler.removeCallbacks(ticker)
        if (playing) MediaDebugSessionsHandler.handler.postDelayed(ticker, 1000)
        session.setPlaybackState(stateAt(anchorPositionMs))
        Log.i(MediaDebugTrigger.TAG, "playing=${if (playing) 1 else 0} slot=$slot")
    }

    /** The position now: the anchor plus the time played since it. */
    private fun positionMs(): Long {
        if (!playing) return anchorPositionMs
        val played = SystemClock.elapsedRealtime() - anchorMs
        return (anchorPositionMs + played).coerceAtMost(DURATION_MS)
    }

    private fun stateAt(positionMs: Long): PlaybackState =
        PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS,
            )
            .setState(
                if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionMs,
                if (playing) 1.0f else 0f,
                SystemClock.elapsedRealtime(),
            )
            .build()

    private fun metadata(): MediaMetadata = MediaMetadata.Builder()
        .putString(MediaMetadata.METADATA_KEY_TITLE, "Pd test track $slot")
        .putString(MediaMetadata.METADATA_KEY_ARTIST, "Pd test artist")
        .putString(MediaMetadata.METADATA_KEY_ALBUM, "Pd test album")
        .putLong(MediaMetadata.METADATA_KEY_DURATION, DURATION_MS)
        .putBitmap(MediaMetadata.METADATA_KEY_ART, artwork(slot))
        .build()

    fun release() {
        MediaDebugSessionsHandler.handler.removeCallbacks(ticker)
        session.isActive = false
        session.release()
    }

    /** A generated test pattern, never anyone's picture: two tones and bars. */
    private fun artwork(seed: Int): Bitmap {
        val size = 640
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(if (seed % 2 == 1) Color.rgb(30, 80, 140) else Color.rgb(120, 60, 30))
        val paint = Paint().apply { color = Color.rgb(230, 235, 240) }
        canvas.drawRect(size * 0.12f, size * 0.30f, size * 0.88f, size * 0.38f, paint)
        canvas.drawRect(size * 0.12f, size * 0.50f, size * 0.62f, size * 0.56f, paint)
        canvas.drawCircle(size * 0.5f, size * 0.72f, size * 0.12f, paint)
        return bitmap
    }

    companion object {
        const val DURATION_MS = 180_000L
        const val SKIP_MS = 15_000L
        const val MAX_VOLUME = 15
    }
}

/** One handler for the fake sessions: their callbacks and ticker share it. */
private object MediaDebugSessionsHandler {
    val handler = Handler(Looper.getMainLooper())
}
