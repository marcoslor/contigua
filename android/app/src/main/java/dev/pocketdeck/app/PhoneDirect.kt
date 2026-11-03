package dev.pocketdeck.app

import dev.pocketdeck.IDeckService
import dev.pocketdeck.proto.PhoneDirectState

/**
 * The app-side direct provider, when the build has one (docs/design/direct-link.md
 * §4.5, transport DIRECT-17). The public build never sets [port], so the shell's
 * `direct.*` callbacks and the startup push are no-ops there.
 */
interface PhoneDirectPort {
    /** The Mac's stored `direct.enable` changed. */
    fun onMacEnable(clientId: String, on: Boolean)

    /** The Mac sent `direct.key`; store it or refuse it, then answer. */
    fun onMacKey(clientId: String, keyHex: String)
}

object PhoneDirect {
    @Volatile var port: PhoneDirectPort? = null

    /** The last state reported to the shell; null when no provider is running. */
    @Volatile var state: PhoneDirectState? = null

    /** Push the last state to a freshly bound shell service. */
    fun push(service: IDeckService) {
        val state = state ?: return
        runCatching { service.setDirectState(state.on, state.reason) }
    }
}
