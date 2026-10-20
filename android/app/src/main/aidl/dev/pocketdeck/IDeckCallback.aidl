package dev.pocketdeck;

/** One-way events from the shell service to the app process. */
oneway interface IDeckCallback {

    /** A Mac asked to pair; the app should show `code` and let the user answer. */
    void onPairingRequest(String requestId, String macName, String code);

    /** A Mac was paired; the app must persist {clientId,name,macFp} (v2 pins). */
    void onPaired(String clientId, String name, String macFp);

    /** Session state changed: connected, which Mac, how many windows are open. */
    void onSessionChanged(boolean connected, String macName, int windows);

    /** The pairing request ended unanswered; the app should dismiss its prompt. */
    void onPairingEnded(String requestId);

    /** The Mac asked to start (or stop) notification sharing for this session. */
    void onNotifySession(boolean forwarding);

    /**
     * The Mac drove Now Playing (`media.command`): `json` is the validated
     * command — `{"action":"play"|"pause"|"next"|"prev"|"seek"|"volume",
     * "key"?,"positionMs"?,"level"?}` (docs/design/notify.md).
     */
    void onMediaCommand(String json);

    /** The Mac picked which phone session Now Playing follows (`media.choose`). */
    void onMediaChoose(String key);

    /**
     * The Mac asked this phone to ring (docs/PROTOCOL.md "Ring"): the app shows
     * the alarm over the lock screen for at most `seconds` (1..30).
     */
    void onRing(int seconds);

    /** The Mac stopped the ring (or it timed out on the Mac's side). */
    void onRingStop();

    /**
     * A Mac clicked the forwarded notification `id` (docs/design/notify.md).
     * The app looks up the action it kept for that id and hands the
     * PendingIntent back to the server with `openNotification`; an unknown id
     * is answered with a null intent.
     */
    void onNotifyOpen(String id, int displayId);

    /**
     * A Mac pressed the forwarded notification's advertised action `index`
     * (`notify.action`). The listener fills its RemoteInput with `text` when it
     * is a reply action and sends the PendingIntent itself; nothing is answered.
     */
    void onNotifyAction(String id, int index, String text);

    /** A Mac cleared the forwarded notification `id` (`notify.dismiss`). */
    void onNotifyDismiss(String id);
}
