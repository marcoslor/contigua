package dev.pocketdeck;

import android.app.PendingIntent;
import android.os.ParcelFileDescriptor;
import dev.pocketdeck.IDeckCallback;

/**
 * The privileged half of PocketDeck, running inside the Shizuku user service as
 * shell (UID 2000). The app process owns all UI, persistence and NSD
 * advertising; this only owns the socket, the virtual displays and injection.
 */
interface IDeckService {

    /** Reserved destroy method required by the Shizuku user-service host. */
    void destroy() = 16777114;

    /**
     * Start the TCP server if it is not already running. Idempotent: returns the
     * port the server is listening on.
     */
    int startServer() = 1;

    /** Stop the TCP server and tear down any active session/windows. */
    void stopServer() = 2;

    /** Install (or clear, with null) the callback used to reach the app process. */
    void setCallback(IDeckCallback cb) = 3;

    /**
     * Replace the paired-client set and identity the server should serve.
     * The app process owns persistence; the JSON is
     * {"deviceId":..,"deviceName":..,"clients":[{"clientId":..,"name":..,"macFp":..}],
     * "self":{"certPem":..,"keyP8":..}} (docs/design/e2ee.md §2/§6).
     */
    void setPairedClients(String json) = 4;

    /** Answer a pending pairing prompt shown to the user. */
    void respondPairing(String requestId, boolean allow) = 5;

    /** Human-readable diagnostics (uid/pid/server state). */
    String status() = 6;

    /**
     * Battery state pushed by the app process: the shell process' context cannot
     * receive ACTION_BATTERY_CHANGED, so the app relays it (and owns the value
     * that goes into `welcome` and the initial `state`).
     */
    void setBatteryState(int percent, boolean charging) = 7;

    /**
     * Keyguard state pushed by the app process, used only when the shell process
     * has no hidden window-manager listener (its broadcast fallback would not be
     * delivered either).
     */
    void setLockedState(boolean locked) = 8;

    /**
     * Share text with the connected Mac (`share.text`). Blocks until queued;
     * returns a ShareStatus code (0 ok, 1 no session, 2 too large, 3 failed).
     */
    int shareText(String text) = 9;

    /**
     * Share a file with the connected Mac (`share.file` + SHARE_DATA + `share.end`),
     * read from `data` until EOF. Blocks until the last byte is queued; returns a
     * ShareStatus code. The service closes its copy of `data`.
     */
    int shareFile(String name, String mime, in ParcelFileDescriptor data) = 10;

    /**
     * The phone's notification-listener grant. The Mac's `notify.enable` is the
     * only person-facing switch; this is the phone-side ability to honour it.
     * The app pushes it here whenever the grant changes, so the session answers
     * `notify.state` at once (a later grant turns forwarding on without another
     * Mac toggle).
     */
    void listenerAccess(boolean granted) = 11;

    /**
     * The notification listener, running in the app process, pushes what it
     * reads. `json` is one {"t":"notify.post"|"notify.remove"|"media.state"}
     * style map as built by NotifyEvents; dropped unless both gates are on.
     */
    void pushDeviceEvent(String json) = 12;

    /**
     * The app's two connection gates (docs/PROTOCOL.md "Error codes"). The
     * server applies them before it starts listening and again on every
     * change; `allowConnections=false` drops the live session immediately.
     */
    void setGates(boolean allowConnections, boolean allowPairings) = 14;

    /**
     * Send a forwarded notification's own action on `displayId` (0 = the
     * phone's screen). The app process owns the id -> PendingIntent map and
     * passes the token here; `intent` is null for an unknown id. The shell
     * UID sends it because it owns the virtual display and may start
     * activities from the background (docs/design/notify.md).
     */
    void openNotification(String id, int displayId, in PendingIntent intent) = 15;

    /**
     * DIRECT-17: a socket the app accepted on the Wi-Fi Aware network. The shell
     * wraps it as an ordinary socket and runs the same TLS pipeline as the LAN
     * listener; false asks the app to bridge bytes instead.
     */
    boolean adoptDirectSocket(in ParcelFileDescriptor fd) = 16;

    /** The app stored the Mac's `direct.key`; true sends `direct.key.ok`. */
    void directKeyStored(boolean ok) = 17;

    /** The app's direct switch and permission state, sent as `direct.state`. */
    void setDirectState(boolean on, String reason) = 18;
}
