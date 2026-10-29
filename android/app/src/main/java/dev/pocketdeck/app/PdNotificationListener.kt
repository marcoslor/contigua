package dev.pocketdeck.app

import android.content.ComponentName
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.NotificationListenerService.Ranking
import android.service.notification.StatusBarNotification
import android.app.Notification
import android.app.RemoteInput
import android.util.Log
import dev.pocketdeck.proto.Json

/**
 * A JVM test's stand-in for the system's channel ranking (rows 5/20). The app
 * leaves it null and reads `getCurrentRanking()` instead; nothing else touches it.
 */
@Volatile
var notifyImportanceForTest: ((String) -> Int?)? = null

/**
 * Reads notifications and the media session for a connected Mac (docs/design/
 * notify.md). Runs in the app process with the notification-listener grant the
 * shell service asks for when the Mac turns sharing on (`cmd notification
 * allow_listener`). Events go through [PdNotificationBridge] (which re-checks
 * the gate) to the shell service over AIDL. A grant that arrives after a failed
 * attempt is announced here, so forwarding starts without another Mac toggle.
 */
class PdNotificationListener : NotificationListenerService() {

    private val bridge = PdNotificationBridge()

    /** Off-main surface for session callbacks and command delivery. */
    private val worker = HandlerThread("pd-notify-media").also { it.start() }
    private val mediaHandler = Handler(worker.looper)

    private var sessionManager: MediaSessionManager? = null
    private var watching = false
    private var attachedController: MediaController? = null

    /** Every active session, in the system's order (docs/design/notify.md). */
    private var sessions: List<MediaController> = emptyList()
    private var callbacksOn: List<MediaController> = emptyList()
    private val listenerComponent by lazy { ComponentName(this, PdNotificationListener::class.java) }

    /** The Mac's pick, while that session is still active. */
    private var chosenKey: String? = null

    /** Opaque per-session keys the phone mints; never a package or a title. */
    private val sessionKeys = HashMap<MediaSession.Token, String>()
    private var keyCounter = 0
    private val labels = HashMap<String, String>()

    /** `media.sessions` is sent only when it changes. */
    private var lastSessions: Map<String, Any?>? = null

    /** Artwork dedupe: the hash of the scaled bytes last sent, per session key. */
    private val lastArtHash = HashMap<String, String>()
    private var lastArtMetadata: MediaMetadata? = null

    /** Live Update coalescing (docs/design/notify.md): one per second per id. */
    private val throttle = NotifyLiveThrottle()
    private val pendingLive = HashMap<String, Map<String, Any?>>()
    private var flushScheduled = false

    /**
     * The content hash of the last forwarded post per id (NOTIFY-19). Hashes,
     * never the text, and never the notification itself. Bounded like the
     * forwarded ids themselves: forgetting one only costs a louder update.
     */
    private val lastContent = BoundedIdMap<String>(MAX_TRACKED)

    /** The last forwarded title hash and whether it carried a bar (row 6). */
    private val lastTitle = BoundedIdMap<String>(MAX_TRACKED)
    private val lastHadBar = BoundedIdMap<Boolean>(MAX_TRACKED)

    /** The per-package-group forwarding states (NOTIFY-20), bounded like the rest. */
    private val groupStates = BoundedIdMap<NotifyGroupState>(MAX_TRACKED)

    /** Which forwarded ids belong to a group, so a removal updates its state. */
    private val groupOf = BoundedIdMap<ForwardedGroup>(MAX_TRACKED)

    /**
     * The summaries the phone deliberately kept while their children were
     * forwarded (NOTIFY-20). Their removals are the only ones not announced: the
     * Mac never saw them. Bounded, like the rest.
     */
    private val skippedSummaries = BoundedIdMap<Boolean>(MAX_TRACKED)

    private val sessionCallback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = scheduleMediaPush()
        override fun onMetadataChanged(metadata: MediaMetadata?) = scheduleMediaPush()
        override fun onSessionDestroyed() = scheduleMediaPush()
    }

    private val activeSessionsListener = object : MediaSessionManager.OnActiveSessionsChangedListener {
        override fun onActiveSessionsChanged(controllers: MutableList<MediaController>?) =
            attachSession(controllers)
    }

    override fun onCreate() {
        super.onCreate()
        // The pushes need the shell-service binder; bind once, not per event.
        runCatching { ShizukuClient.ensureBound(this) }
        PdNotificationBridge.mediaSink = { json -> deliverMediaAction(json) }
        PdNotificationBridge.chooseSink = { key -> deliverChoose(key) }
        PdNotificationBridge.actionSink = { id, index, text -> deliverAction(id, index, text) }
        PdNotificationBridge.dismissSink = { id -> deliverDismiss(id) }
        // The gate can open long after the stack was read (the Mac opts in on
        // its own schedule), and everything pushed before it is dropped.
        DeckState.addListener(gateObserver)
    }

    override fun onDestroy() {
        DeckState.removeListener(gateObserver)
        PdNotificationBridge.mediaSink = null
        PdNotificationBridge.chooseSink = null
        PdNotificationBridge.actionSink = null
        PdNotificationBridge.dismissSink = null
        NotifyIntents.clear()
        // The live state belongs to the worker thread; quitSafely still runs this.
        mediaHandler.post {
            mediaHandler.removeCallbacks(liveFlush)
            throttle.clear()
            pendingLive.clear()
        }
        sessionManager?.let { runCatching { it.removeOnActiveSessionsChangedListener(activeSessionsListener) } }
        sessionManager = null
        watching = false
        detachSession()
        lastArtHash.clear()
        lastArtMetadata = null
        lastSessions = null
        sessionKeys.clear()
        lastContent.clear()
        lastTitle.clear()
        lastHadBar.clear()
        groupStates.clear()
        groupOf.clear()
        skippedSummaries.clear()
        worker.quitSafely()
        super.onDestroy()
    }

    override fun onListenerConnected() {
        // The grant is live from here: tell the shell session (a later grant
        // turns forwarding on by itself), then read the stack and watch it.
        ShizukuClient.current()?.let { runCatching { it.listenerAccess(true) } }
        if (watchSessions() == null) return
        scanSessions("connect")
    }

    override fun onListenerDisconnected() {
        ShizukuClient.current()?.let { runCatching { it.listenerAccess(false) } }
        super.onListenerDisconnected()
    }

    /**
     * Registers the system's change signal once; null when the grant is not live
     * yet (the next scan retries). A listener that cannot be registered still
     * gets the scans below.
     */
    private fun watchSessions(): MediaSessionManager? {
        val manager = runCatching { getSystemService(MediaSessionManager::class.java) }.getOrNull()
            ?: return null
        if (!watching) {
            val ok = runCatching {
                manager.addOnActiveSessionsChangedListener(activeSessionsListener, listenerComponent)
            }.onFailure { Log.w(TAG, "media session watch failed: ${it.javaClass.simpleName}") }
                .isSuccess
            if (!ok) return null
            watching = true
        }
        sessionManager = manager
        return manager
    }

    /**
     * Reads the session stack again. A read at connect can land before a track
     * exists and a session can appear while the Mac has not opted in yet
     * (everything sent then is dropped by the gate), so the gate opening, a
     * command that finds nothing and a listener that could not register its
     * callback each re-read.
     */
    private fun scanSessions(reason: String) {
        val manager = sessionManager ?: watchSessions() ?: return
        val list = runCatching { manager.getActiveSessions(listenerComponent) }
            .onFailure { Log.w(TAG, "media scan failed: ${it.javaClass.simpleName}") }
            .getOrNull() ?: return
        Log.i(TAG, "media scan n=${list.size} reason=$reason")
        attachSession(list)
    }

    /** The Mac's (or the phone's) sharing switch moved: read again and resend. */
    private val gateObserver: () -> Unit = {
        if (bridge.gate()) mediaHandler.post { scanSessions("gate") }
    }

    /**
     * Keeps the active sessions in the system's order and follows the chosen
     * one: the Mac's pick while it is still there, else the first session.
     * The callbacks are registered on every session so the list's `playing`
     * flags stay true.
     */
    private fun attachSession(controllers: List<MediaController>?) {
        val list = controllers.orEmpty()
        for (controller in callbacksOn) {
            if (list.none { it === controller }) runCatching { controller.unregisterCallback(sessionCallback) }
        }
        for (controller in list) {
            if (callbacksOn.none { it === controller }) runCatching { controller.registerCallback(sessionCallback) }
        }
        callbacksOn = list
        sessions = list
        attachedController = pickChosen()
        scheduleMediaPush()
    }

    private fun detachSession() {
        for (controller in callbacksOn) runCatching { controller.unregisterCallback(sessionCallback) }
        callbacksOn = emptyList()
        sessions = emptyList()
        attachedController = null
    }

    /** The session Now Playing follows, and the key the Mac knows it by. */
    private fun pickChosen(): MediaController? {
        val keys = sessions.map { keyOf(it) }
        val chosen = MediaControl.chooseKey(keys, chosenKey)
        chosenKey = chosen
        return sessions.firstOrNull { keyOf(it) == chosen }
    }

    /** An opaque per-session key, stable while the session lives. */
    private fun keyOf(controller: MediaController): String {
        val token = controller.sessionToken
        sessionKeys[token]?.let { return it }
        val key = "s${++keyCounter}"
        sessionKeys[token] = key
        return key
    }

    /** The app label for `media.sessions`; never a title. */
    private fun label(pkg: String): String = labels.getOrPut(pkg) {
        runCatching {
            val info = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(info).toString()
        }.getOrDefault(pkg)
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
            pushSessions()
            return
        }
        val key = keyOf(controller)
        val metadata = controller.metadata
        val playing = state.state == PlaybackState.STATE_PLAYING
        val volume = runCatching { controller.playbackInfo }.getOrNull()
        bridge.media(
            NotifyEvents.mediaState(
                playing = playing,
                pkg = controller.packageName,
                title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE),
                artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST),
                album = metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM),
                durationMs = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.takeIf { it > 0 },
                positionMs = state.position.takeIf { it >= 0 },
                rate = if (playing) state.playbackSpeed.toDouble() else 0.0,
                key = key,
                canSeek = state.actions and PlaybackState.ACTION_SEEK_TO != 0L,
                volume = volume?.currentVolume,
                volumeMax = volume?.maxVolume,
            ),
        )
        pushSessions()
        pushArtwork(controller, key, metadata)
    }

    /** `media.sessions`, only when the list or the chosen key moved. */
    private fun pushSessions() {
        val infos = sessions.map { controller ->
            MediaSessionInfo(
                key = keyOf(controller),
                pkg = controller.packageName,
                app = label(controller.packageName),
                playing = controller.playbackState?.state == PlaybackState.STATE_PLAYING,
            )
        }
        val wire = MediaControl.sessionsWire(infos, chosenKey)
        // Only what a Mac actually got may be remembered: a push dropped by the
        // gate must be sent once sharing opens, not skipped as "unchanged".
        if (!bridge.gate()) return
        if (wire == lastSessions) return
        lastSessions = wire
        bridge.sessions(wire)
    }

    /**
     * `media.art` once per change (docs/design/notify.md): the scaled bytes are
     * hashed, and a session that lost its artwork sends the key alone to clear
     * it. Only the size, the dimensions and a hash prefix are logged.
     */
    private fun pushArtwork(controller: MediaController, key: String, metadata: MediaMetadata?) {
        // Nothing is encoded or remembered while sharing is off (docs/design/
        // notify.md: no new gate, and the artwork gate is the same one).
        if (!bridge.gate()) return
        // The metadata object changes exactly when the session's artwork may have.
        if (metadata != null && metadata === lastArtMetadata) return
        lastArtMetadata = metadata
        val art = MediaArtRules.encode(MediaArtwork.sourceFor(this, metadata))
        if (art == null) {
            if (lastArtHash.remove(key) != null) {
                bridge.art(mapOf("t" to "media.art", "key" to key))
                Log.i(TAG, "media.art cleared")
            }
            return
        }
        val hash = MediaArtRules.hash(art.data)
        if (lastArtHash[key] == hash) return
        lastArtHash[key] = hash
        bridge.art(art.wire(key, NotifyPictures::base64))
        Log.i(TAG, "media.art w=${art.width} h=${art.height} size=${art.data.size} hash=${hash.take(8)}")
    }

    /** `media.command`, as the shell service validated and re-encoded it. */
    private fun deliverMediaAction(json: String) {
        val obj = runCatching { Json.parseObject(json) }.getOrNull() ?: return
        val command = MediaControl.commandFromWire(obj) ?: return
        mediaHandler.post { runMediaCommand(command) }
    }

    private fun runMediaCommand(command: MediaCommand) {
        var controller = controllerFor(command)
        if (controller == null) {
            // Silence looked like "no session attached" once: the stack may have
            // moved without the system telling us, so read it before giving up.
            scanSessions("command")
            controller = controllerFor(command)
        }
        if (controller == null) {
            Log.i(TAG, "media command ${command.action} ignored: no session attached")
            return
        }
        val controls = controller.transportControls
        when (command.action) {
            "play" -> controls.play()
            "pause" -> controls.pause()
            "next" -> controls.skipToNext()
            "prev" -> controls.skipToPrevious()
            "seek" -> {
                val duration = controller.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)
                    ?.takeIf { it > 0 }
                val position = MediaControl.positionClamp(command.positionMs ?: return, duration)
                controls.seekTo(position)
                Log.i(TAG, "media seek positionMs=$position")
            }
            "volume" -> {
                val max = runCatching { controller.playbackInfo?.maxVolume }.getOrNull()
                val level = MediaControl.levelClamp(command.level ?: return, max)
                runCatching { controller.setVolumeTo(level, 0) }
                    .onFailure { Log.w(TAG, "media volume failed: ${it.javaClass.simpleName}") }
                Log.i(TAG, "media volume level=$level max=${max ?: -1}")
            }
        }
    }

    /** Which session a command acts on: the Mac's key, else the chosen one. */
    private fun controllerFor(command: MediaCommand): MediaController? = when (val key = command.key) {
        null -> attachedController
        else -> sessions.firstOrNull { keyOf(it) == key }
    }

    /** `media.choose`: the Mac picks which app Now Playing follows. */
    private fun deliverChoose(key: String) {
        mediaHandler.post {
            val match = sessions.firstOrNull { keyOf(it) == key }
            if (match == null) {
                Log.i(TAG, "media.choose unknown key")
                return@post
            }
            chosenKey = key
            attachedController = match
            pushMediaState()
            Log.i(TAG, "media.choose key=$key")
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
        val title = extras.getString(Notification.EXTRA_TITLE)
            ?: extras.getString(Notification.EXTRA_TITLE_BIG)
        val text = extras.getString(Notification.EXTRA_TEXT)
            ?: extras.getString(Notification.EXTRA_BIG_TEXT)
        // NOTIFY-19: the same decision Android makes. The comparison is over
        // content hashes kept in memory; the text never leaves this block.
        val contentHash = NotifyEvents.contentHash(title, text)
        val titleHash = NotifyEvents.titleHash(title)
        // Row 6: a bar that only moves is not news, even when its text moves.
        val hadBar = extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false) ||
            extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0) > 0
        // Rows 5/20: the channel's importance can only make a post quieter.
        val importance = importanceOf(sbn)
        Log.i(TAG, "notify importance=${importance?.toString() ?: "unknown"} id=$id")
        val alert = NotifyEvents.alerts(
            firstPost = lastContent.get(id) == null,
            onlyAlertOnce = notification.flags and NotifyEvents.FLAG_ONLY_ALERT_ONCE != 0,
            contentChanged = lastContent.get(id) != contentHash,
            progressOnly = NotifyEvents.progressOnly(
                previousHadBar = lastHadBar.get(id) == true,
                hadBar = hadBar,
                previousTitleHash = lastTitle.get(id),
                titleHash = titleHash,
            ),
        ) && !NotifyEvents.quietByImportance(importance)
        val groupKey = sbn.groupKey?.takeIf { it.isNotEmpty() }
        val summary = notification.flags and NotifyEvents.FLAG_GROUP_SUMMARY != 0
        var event = NotifyEvents.notificationEvent(
            id = id,
            pkg = sbn.packageName,
            title = title,
            text = text,
            when_ = sbn.postTime,
            alert = alert,
            actions = actions,
            ongoing = sbn.isOngoing,
            debugPoster = debugPoster,
            live = live,
            group = groupKey?.let { NotifyEvents.groupHash(sbn.packageName, it) },
        ) ?: return
        // NOTIFY-20: a group summary never lands on top of its children.
        if (groupKey != null) {
            val groupActions = groupEvent(
                sbn.packageName,
                groupKey,
                if (summary) NotifyGroupEvent.SummaryPosted(id) else NotifyGroupEvent.ChildPosted(id),
            )
            var skip = false
            for (action in groupActions) when (action) {
                NotifyGroupAction.Skip -> skip = true
                is NotifyGroupAction.RemoveSummary -> {
                    // The child arrives after a forwarded summary: take the
                    // summary away first, so the Mac never shows both.
                    lastContent.remove(action.id)
                    groupOf.remove(action.id)
                    NotifyIntents.remove(action.id)
                    mediaHandler.post { NotifyEvents.removedEvent(action.id)?.let { bridge.post(it) } }
                    Log.i(TAG, "notify group summary replaced id=${action.id}")
                }
                NotifyGroupAction.Forward -> Unit
            }
            if (!skip && summary &&
                !NotifyEvents.summaryAlerts(notification.groupAlertBehavior)
            ) {
                // Row 13: a lone summary the app wanted quiet (children only)
                // is listed, never presented.
                event = event + ("alert" to false)
            }
            if (skip) {
                skippedSummaries.put(id, true)
                Log.i(TAG, "notify group summary skipped: children active")
                return
            }
            groupOf.put(id, ForwardedGroup(sbn.packageName, groupKey, summary))
            // A notification forwarded after earlier being kept is announced
            // on removal like any other.
            skippedSummaries.remove(id)
        }
        lastContent.put(id, contentHash)
        lastTitle.put(id, titleHash)
        lastHadBar.put(id, hadBar)
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
     * The channel's importance for this notification (rows 5/20), from the
     * system's ranking of its key. Null when the system does not answer for it;
     * today's alert rules then apply.
     */
    private fun importanceOf(sbn: StatusBarNotification): Int? {
        notifyImportanceForTest?.let { return it(sbn.key ?: "") }
        return runCatching {
            val map = getCurrentRanking() ?: return@runCatching null
            val ranking = Ranking()
            if (map.getRanking(sbn.key, ranking)) ranking.importance else null
        }.getOrNull()
    }

    /**
     * Runs one group event through the machine (NOTIFY-20) and logs the
     * transition with its state and action count only — never a group key.
     */
    private fun groupEvent(
        pkg: String,
        groupKey: String,
        event: NotifyGroupEvent,
    ): List<NotifyGroupAction> {
        val key = "$pkg\u0000$groupKey"
        val from = groupStates.get(key) ?: NotifyGroupState()
        val (next, actions) = NotifyGroups.transition(from, event)
        if (next.phase == NotifyGroupPhase.EMPTY) groupStates.remove(key) else groupStates.put(key, next)
        val name = when (event) {
            is NotifyGroupEvent.ChildPosted -> "child-post"
            is NotifyGroupEvent.ChildGone -> "child-gone"
            is NotifyGroupEvent.SummaryPosted -> "summary-post"
            is NotifyGroupEvent.SummaryGone -> "summary-gone"
        }
        Log.i(
            TAG,
            "notify group $pkg: ${from.phase} --$name--> ${next.phase}"
                + " children=${next.children.size} actions=${actions.size}",
        )
        return actions
    }

    /** A forwarded notification that belongs to a group (NOTIFY-20). */
    private data class ForwardedGroup(val pkg: String, val groupKey: String, val summary: Boolean)

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
            // Every post carries its picture again, an update with the same one
            // too: the Mac replaces the whole banner, so a skipped picture
            // would leave the updated banner without it.
            val image = NotifyImageRules.encode(NotifyPictures.sourceFor(this, picture)) ?: return@post
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
        lastContent.remove(id)
        lastTitle.remove(id)
        lastHadBar.remove(id)
        val grouped = groupOf.remove(id)
        if (grouped != null) {
            groupEvent(
                grouped.pkg,
                grouped.groupKey,
                if (grouped.summary) NotifyGroupEvent.SummaryGone else NotifyGroupEvent.ChildGone(id),
            )
        }
        // Every other removal is announced, even after the forwarded-id map
        // forgot the id: the Mac still holds that banner, and swallowing the
        // removal would leave a ghost (NOTIFY-20). Only an id the phone
        // deliberately kept — a skipped summary — was never forwarded.
        if (skippedSummaries.remove(id) != null) {
            Log.i(TAG, "notify remove id=$id was not forwarded")
            return
        }
        // Posts leave through mediaHandler; the removal takes the same queue so
        // it can never overtake its own post (a ghost banner on the Mac), and
        // the live state is only ever touched on that one thread.
        mediaHandler.post {
            throttle.forget(id)
            pendingLive.remove(id)
            NotifyEvents.removedEvent(id)?.let { bridge.post(it) }
        }
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

        /** Content hashes and group links kept in memory (NOTIFY-19, NOTIFY-20). */
        const val MAX_TRACKED = 400

    }
}
