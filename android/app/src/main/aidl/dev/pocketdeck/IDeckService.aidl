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
}
