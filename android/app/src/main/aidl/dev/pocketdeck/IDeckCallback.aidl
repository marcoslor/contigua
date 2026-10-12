package dev.pocketdeck;

/** One-way events from the shell service to the app process. */
oneway interface IDeckCallback {

    /** A Mac asked to pair; the app should show `code` and let the user answer. */
    void onPairingRequest(String requestId, String macName, String code);

    /** A Mac was paired; the app must persist {clientId,name,keyHex}. */
    void onPaired(String clientId, String name, String keyHex);

    /** Session state changed: connected, which Mac, how many windows are open. */
    void onSessionChanged(boolean connected, String macName, int windows);
}
