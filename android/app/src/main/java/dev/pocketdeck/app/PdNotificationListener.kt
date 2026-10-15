package dev.pocketdeck.app

import android.content.ComponentName
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.HandlerThread
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.app.Notification
import android.util.Log

/**
 * Reads notifications and the media session for a connected Mac (docs/design/
 * notify.md). Runs in the app process with the notification-listener grant the
 * shell service handed over at the per-phone opt-in (`cmd notification
 * allow_listener`). Events go through [PdNotificationBridge] (which re-checks
 * both gates) to the shell service over AIDL.
 */
class PdNotificationListener : NotificationListenerService() {

    private val bridge = PdNotificationBridge(this)

    /** Off-main surface for session callbacks and command delivery. */
    private val worker = HandlerThread("pd-notify-media").also { it.start() }
    private val mediaHandler = Handler(worker.looper)

    private var sessionManager: MediaSessionManager? = null
    private var attachedController: MediaController? = null

    private val sessionCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = scheduleMediaPush()
        override fun onMetadataChanged(metadata: android.media.MediaMetadata?) = scheduleMediaPush()
    }

    private val activeSessionsListener = object : MediaSessionManager.OnActiveSessionsChangedListener {
        override fun onActiveSessionsChanged(controllers: MutableList<MediaController>?) =
            attachSession(controllers)
    }

    override fun onCreate() {
        super.onCreate()
        // The pushes need the shell-service binder; bind once, not per event.
        ShizukuClient.ensureBound(this)
        PdNotificationBridge.mediaSink = { action -> deliverMediaAction(action) }
    }

    override fun onDestroy() {
        PdNotificationBridge.mediaSink = null
        sessionManager?.let { runCatching { it.removeOnActiveSessionsChangedListener(activeSessionsListener) } }
        sessionManager = null
        detachSession()
        worker.quitSafely()
        super.onDestroy()
    }

    override fun onListenerConnected() {
        // The grant is live from here: watch the session stack and pick the one
        // the person is currently playing on.
        runCatching {
            val manager = getSystemService(MediaSessionManager::class.java)
            sessionManager = manager
            val component = ComponentName(this, PdNotificationListener::class.java)
            manager.addOnActiveSessionsChangedListener(activeSessionsListener, component)
            attachSession(manager.getActiveSessions(component))
        }.onFailure { Log.w(TAG, "media session watch failed: ${it.message}") }
    }

    /** The priority stack's top session is the one Now Playing shows. */
    private fun attachSession(controllers: List<MediaController>?) {
        val chosen = controllers?.firstOrNull()
        val current = attachedController
        if (chosen === current) return
        current?.let { runCatching { it.unregisterCallback(sessionCallback) } }
        attachedController = chosen
        chosen?.registerCallback(sessionCallback)
        scheduleMediaPush()
    }

    private fun detachSession() {
        attachedController?.let { runCatching { it.unregisterCallback(sessionCallback) } }
        attachedController = null
    }

    /** Coalesces stormy state/metadata callbacks into at most one push per [MEDIA_MERGE_MS]. */
    private fun scheduleMediaPush() {
        mediaHandler.removeCallbacks(mediaPush)
        mediaHandler.postDelayed(mediaPush, MEDIA_MERGE_MS)
    }

    private val mediaPush = Runnable { pushMediaState() }

    private fun pushMediaState() {
        val controller = attachedController
        val state = controller?.playbackState
        if (controller == null || state == null) {
            bridge.media(NotifyEvents.mediaState(false, null, null, null, null, null, null, 0.0))
            return
        }
        val playing = state.state == PlaybackState.STATE_PLAYING
        bridge.media(
            NotifyEvents.mediaState(
                playing = playing,
                pkg = controller.packageName,
                title = controller.metadata?.getString(android.media.MediaMetadata.METADATA_KEY_TITLE),
                artist = controller.metadata?.getString(android.media.MediaMetadata.METADATA_KEY_ARTIST),
                album = controller.metadata?.getString(android.media.MediaMetadata.METADATA_KEY_ALBUM),
                durationMs = controller.metadata?.getLong(android.media.MediaMetadata.METADATA_KEY_DURATION)
                    ?.takeIf { it > 0 },
                positionMs = state.position.takeIf { it >= 0 },
                rate = if (playing) state.playbackSpeed.toDouble() else 0.0,
            ),
        )
    }

    private fun deliverMediaAction(action: String) {
        val command = NotifyEvents.validMediaCommand(action) ?: return
        mediaHandler.post { runMediaCommand(command) }
    }

    private fun runMediaCommand(command: String) {
        val controls = attachedController?.transportControls
        if (controls == null) {
            Log.i(TAG, "media command $command ignored: no session attached")
            return
        }
        when (command) {
            "play" -> controls.play()
            "pause" -> controls.pause()
            "next" -> controls.skipToNext()
            "prev" -> controls.skipToPrevious()
        }
    }

    // ---- notification events ----------------------------------------------

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        // Ongoing notifications are service chrome; a person never answers them,
        // and the media session is delivered separately anyway.
        if (sbn.packageName in NotifyEvents.skippedPackages || sbn.isOngoing) return
        val extras = sbn.notification?.extras ?: return
        NotifyEvents.notificationEvent(
            id = forwardId(sbn),
            pkg = sbn.packageName,
            title = extras.getString(Notification.EXTRA_TITLE)
                ?: extras.getString(Notification.EXTRA_TITLE_BIG),
            text = extras.getString(Notification.EXTRA_TEXT)
                ?: extras.getString(Notification.EXTRA_BIG_TEXT),
            when_ = sbn.postTime,
        )?.let { bridge.post(it) }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName in NotifyEvents.skippedPackages) return
        NotifyEvents.removedEvent(forwardId(sbn))?.let { bridge.post(it) }
    }

    /**
     * A stable per-notification id for the Mac: the system key compressed to
     * [A-Za-z0-9-._] and bounded to 64 chars.
     */
    private fun forwardId(sbn: StatusBarNotification): String {
        val raw = sbn.key ?: "${sbn.packageName}:${sbn.id}"
        val compressed = raw.map { if (it.isLetterOrDigit() || it in "-._") it else '_' }.joinToString("")
        return if (compressed.length <= 64) compressed else compressed.substring(compressed.length - 64)
    }

    private companion object {
        const val TAG = "PocketDeckApp"
        const val MEDIA_MERGE_MS = 200L
    }
}
