package dev.pocketdeck;

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
     * {"deviceId":..,"deviceName":..,"clients":[{"clientId":..,"name":..,"key":..}]}.
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
}
