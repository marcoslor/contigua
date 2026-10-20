package dev.pocketdeck.app

import android.content.ComponentName
import android.content.Intent
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.app.Notification
import android.app.RemoteInput
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

    /** Live Update coalescing (docs/design/notify.md): one per second per id. */
    private val throttle = NotifyLiveThrottle()
    private val pendingLive = HashMap<String, Map<String, Any?>>()
    private var flushScheduled = false

    /** The picture already sent for an id, by content hash (in memory only). */
    private val sentImages = BoundedIdMap<Int>(64)

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
        PdNotificationBridge.actionSink = { id, index, text -> deliverAction(id, index, text) }
        PdNotificationBridge.dismissSink = { id -> deliverDismiss(id) }
    }

    override fun onDestroy() {
        PdNotificationBridge.mediaSink = null
        PdNotificationBridge.actionSink = null
        PdNotificationBridge.dismissSink = null
        NotifyIntents.clear()
        throttle.clear()
        pendingLive.clear()
        sentImages.clear()
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
        val notification = sbn.notification ?: return
        val extras = notification.extras ?: return
        val debugPoster = NotifyEvents.debugPoster(
            sbn.packageName,
            extras.getBoolean(NotifyEvents.DEBUG_POSTER_EXTRA, false),
            dev.pocketdeck.BuildConfig.DEBUG,
        )
        // Ongoing notifications are service chrome; a person never answers
        // them, and the media session is delivered separately anyway. An
        // Android 16 Live Update is the exception: the system promoted it, so
        // its progress is the point (docs/design/notify.md). The debug poster's
        // own ongoing notification stays forwardable so the rules are testable.
        val promoted = NotifyEvents.promoted(notification.flags, sbn.isOngoing)
        if (sbn.packageName in NotifyEvents.skippedPackages && !debugPoster) return
        if (sbn.isOngoing && !promoted && !debugPoster) return
        val id = forwardId(sbn)
        val candidates = actionCandidates(notification)
        val actions = NotifyEvents.selectActions(candidates)
        val live = liveFor(sbn, notification, promoted, debugPoster)
        val event = NotifyEvents.notificationEvent(
            id = id,
            pkg = sbn.packageName,
            title = extras.getString(Notification.EXTRA_TITLE)
                ?: extras.getString(Notification.EXTRA_TITLE_BIG),
            text = extras.getString(Notification.EXTRA_TEXT)
                ?: extras.getString(Notification.EXTRA_BIG_TEXT),
            when_ = sbn.postTime,
            actions = actions,
            ongoing = sbn.isOngoing,
            debugPoster = debugPoster,
            live = live,
        ) ?: return
        // The Mac can only ask for an id it received; the action stays here and
        // is never serialized onto the wire (docs/design/notify.md).
        val kept = actions.mapNotNull { candidate ->
            val action = notification.actions?.getOrNull(candidate.index) ?: return@mapNotNull null
            val intent = action.actionIntent ?: return@mapNotNull null
            NotifyAction(
                index = candidate.index,
                intent = intent,
                remoteInput = if (candidate.reply) {
                    action.remoteInputs?.firstOrNull { it.allowFreeFormInput }
                } else {
                    null
                },
            )
        }
        NotifyIntents.put(
            id,
            NotifyRecord(
                key = sbn.key ?: "${sbn.packageName}:${sbn.id}",
                contentIntent = notification.contentIntent,
                actions = kept,
                ongoing = sbn.isOngoing,
                noClear = notification.flags and Notification.FLAG_NO_CLEAR != 0,
            ),
        )
        deliver(id, event, live, if (live == null) notification else null)
    }

    /**
     * The `live` field for a promoted ongoing notification (docs/design/notify.md).
     * The logcat line is the emulator's record of what Android 16 did: the flag
     * it set and whether it considers the notification promotable. No text.
     */
    private fun liveFor(
        sbn: StatusBarNotification,
        notification: Notification,
        promoted: Boolean,
        debugPoster: Boolean,
    ): Map<String, Any?>? {
        if (!sbn.isOngoing) return null
        val promotable = if (Build.VERSION.SDK_INT >= 36) {
            runCatching { notification.hasPromotableCharacteristics() }.getOrDefault(false)
        } else {
            false
        }
        Log.i(
            TAG,
            "notify live promoted=${if (promoted) 1 else 0} promotable=${if (promotable) 1 else 0}"
                + " style=${styleName(notification)}",
        )
        if (!promoted && !debugPoster) return null
        val extras = notification.extras
        val indeterminate = extras?.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false) == true
        val progress = if (indeterminate) {
            null
        } else {
            NotifyEvents.progressFraction(
                extras?.getInt(Notification.EXTRA_PROGRESS, -1) ?: -1,
                extras?.getInt(Notification.EXTRA_PROGRESS_MAX, 0) ?: 0,
            )
        }
        val chip = if (Build.VERSION.SDK_INT >= 36) notification.shortCriticalText else null
        val chrono = if (extras?.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER, false) == true) {
            notification.`when`
        } else {
            null
        }
        val countDown = extras?.getBoolean(Notification.EXTRA_CHRONOMETER_COUNT_DOWN, false) == true
        // A promoted notification with none of the extras is still live: the
        // empty object is the marker the Mac's menu bar section needs.
        return NotifyEvents.liveWire(progress, chip, chrono, countDown) ?: emptyMap()
    }

    /** The style's class name only ("ProgressStyle"), never any content. */
    private fun styleName(notification: Notification): String {
        val template = notification.extras?.getString(Notification.EXTRA_TEMPLATE) ?: return "none"
        return template.substringAfterLast('$').substringAfterLast('.')
    }

    /**
     * Sends a post and, for a notification with a picture, its `notify.image`
     * right after it (docs/design/notify.md). Live updates are coalesced to at
     * most one per second per id; the newest state wins.
     */
    private fun deliver(
        id: String,
        event: Map<String, Any?>,
        live: Map<String, Any?>?,
        picture: Notification?,
    ) {
        mediaHandler.post {
            if (live != null) {
                val now = SystemClock.uptimeMillis()
                if (!throttle.due(id, now)) {
                    pendingLive[id] = event
                    scheduleLiveFlush()
                    return@post
                }
                pendingLive.remove(id)
            }
            bridge.post(event)
            if (picture == null) return@post
            val image = NotifyImageRules.encode(NotifyPictures.sourceFor(this, picture)) ?: return@post
            val hash = image.data.contentHashCode()
            // An update that repeats the same picture is not sent again.
            if (sentImages.get(id) == hash) return@post
            sentImages.put(id, hash)
            bridge.post(image.wire(id, NotifyPictures::base64))
            Log.i(
                TAG,
                "notify.image id=$id mime=${image.mime} w=${image.width} h=${image.height}"
                    + " size=${image.data.size}",
            )
        }
    }

    private fun scheduleLiveFlush() {
        if (flushScheduled) return
        flushScheduled = true
        mediaHandler.postDelayed(liveFlush, throttle.intervalMs)
    }

    private val liveFlush = object : Runnable {
        override fun run() {
            flushScheduled = false
            val now = SystemClock.uptimeMillis()
            var next = Long.MAX_VALUE
            for ((id, event) in pendingLive.toList()) {
                if (throttle.due(id, now)) {
                    pendingLive.remove(id)
                    bridge.post(event)
                } else {
                    next = minOf(next, throttle.waitMs(id, now))
                }
            }
            if (pendingLive.isNotEmpty()) {
                flushScheduled = true
                mediaHandler.postDelayed(this, next.coerceIn(50L, throttle.intervalMs))
            }
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val notification = sbn.notification
        val debugPoster = notification != null && NotifyEvents.debugPoster(
            sbn.packageName,
            notification.extras?.getBoolean(NotifyEvents.DEBUG_POSTER_EXTRA, false) == true,
            dev.pocketdeck.BuildConfig.DEBUG,
        )
        if (sbn.packageName in NotifyEvents.skippedPackages && !debugPoster) return
        val id = forwardId(sbn)
        NotifyIntents.remove(id)
        throttle.forget(id)
        pendingLive.remove(id)
        sentImages.remove(id)
        NotifyEvents.removedEvent(id)?.let { bridge.post(it) }
    }

    /** The phone's actions, in its own order, for [NotifyEvents.selectActions]. */
    private fun actionCandidates(notification: Notification): List<NotifyEvents.ActionCandidate> =
        notification.actions?.mapIndexed { index, action ->
            NotifyEvents.ActionCandidate(
                index = index,
                title = action.title?.toString(),
                hasIntent = action.actionIntent != null,
                reply = action.remoteInputs?.any { it.allowFreeFormInput } == true,
                contextual = Build.VERSION.SDK_INT >= 31 && action.isContextual,
            )
        } ?: emptyList()

    /**
     * `notify.action`: press the action the phone advertised for that id. The
     * reply text only ever reaches the RemoteInput; the log carries its length.
     */
    private fun deliverAction(id: String, index: Int, text: String?) {
        mediaHandler.post {
            val record = NotifyIntents.get(id)
            if (record == null) {
                Log.i(TAG, "notify.action unknown id")
                return@post
            }
            val action = record.action(index)
            if (action == null) {
                Log.i(TAG, "notify.action unknown index=$index")
                return@post
            }
            NotifyEvents.actionTextRefusal(text, action.remoteInput != null)?.let { why ->
                Log.i(TAG, "notify.action refused: $why")
                return@post
            }
            val fillIn = Intent()
            if (!text.isNullOrEmpty() && action.remoteInput != null) {
                val results = Bundle().apply { putCharSequence(action.remoteInput.resultKey, text) }
                RemoteInput.addResultsToIntent(arrayOf(action.remoteInput), fillIn, results)
            }
            runCatching { action.intent.send(this, 0, fillIn) }
                .onFailure { Log.w(TAG, "notify.action failed: ${it.javaClass.simpleName}") }
            Log.i(TAG, "notify.action sent index=$index reply=${!text.isNullOrEmpty()} textLen=${text?.length ?: 0}")
        }
    }

    /** `notify.dismiss`: clear the phone's notification, unless it is not ours to clear. */
    private fun deliverDismiss(id: String) {
        mediaHandler.post {
            val record = NotifyIntents.get(id)
            if (record == null) {
                Log.i(TAG, "notify.dismiss unknown id")
                return@post
            }
            if (!NotifyEvents.canDismiss(record.ongoing, record.noClear)) {
                Log.i(TAG, "notify.dismiss skipped: ongoing")
                return@post
            }
            runCatching { cancelNotification(record.key) }
                .onFailure { Log.w(TAG, "notify.dismiss failed: ${it.javaClass.simpleName}") }
            Log.i(TAG, "notify.dismiss sent")
        }
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
