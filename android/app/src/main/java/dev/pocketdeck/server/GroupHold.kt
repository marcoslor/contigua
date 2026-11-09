package dev.pocketdeck.server

/**
 * Whether a streaming display's keep-awake machinery may touch the display's
 * power group (docs/specs/phone-app.md PHONE-22).
 *
 * The display-scoped SCREEN_BRIGHT wake lock and the keep-alive `userActivity`
 * poke both name the streaming display, but on a build that ignores
 * `OWN_DISPLAY_GROUP` that display sits in the panel's group 0 (One UI; see
 * docs/research/lock-fade.md). Either one then keeps the phone's own screen
 * awake. A display with its own group never keeps the panel awake, so it keeps
 * today's lock and poke in every state.
 */
internal data class GroupHold(
    /** Hold the display-scoped SCREEN_BRIGHT wake lock for the open streams. */
    val displayLock: Boolean,
    /** Send the keep-alive `userActivity` poke for the open streams. */
    val poke: Boolean,
)

/**
 * The one pure decision: the wake owner, whether the streaming displays share
 * the panel's group, and whether any stream is open.
 *
 * Today the owner and the group change nothing: the episode holds every open
 * stream's display lock until its close, and every step pokes.
 */
internal fun groupHold(
    owner: WakeOwner,
    sharedGroup: Boolean,
    streamsUp: Boolean,
): GroupHold = when {
    !streamsUp -> GroupHold(displayLock = false, poke = false)
    else -> GroupHold(displayLock = true, poke = true)
}
