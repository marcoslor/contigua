// The direct provider's shared constants (docs/design/direct-link.md §4.1,
// §6). Only the direct build compiles this source set.
package dev.pocketdeck.direct

object DirectConfig {
    /** The Wi-Fi Aware service name; the Mac helper declares the same one. */
    const val SERVICE_NAME = "_pocketdeck-nan._tcp"

    /** The TCP port the Mac dials once the NDP is up. */
    const val PORT = 47800

    /** One service-specific-info window (docs/design/direct-link.md §6). */
    const val SSI_WINDOW_SECONDS = 600L
}
