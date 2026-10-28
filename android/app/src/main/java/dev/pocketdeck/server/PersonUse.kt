package dev.pocketdeck.server

/** One way the person used the phone, read from a `state` emission. */
internal enum class PersonUse {
    /** The keyguard went unlocked (`state.locked` false). */
    UNLOCKED,

    /** Display 0 went on (`state.screen` off -> on). */
    SCREEN_ON,

    /** Display 0 went off (`state.screen` on -> off). */
    SCREEN_OFF,
}

/**
 * The edges of the person's own use for the wake machine
 * (docs/specs/controls.md CTRL-7).
 *
 * A `state` stream repeats the same locked/screen values on every battery or
 * DND change, so only a change is a use. The first screen reading of a session
 * is not an edge: a reconnect must not read the phone's current picture as a
 * new wake. An already unlocked phone does count once: with no lock there is
 * nothing of ours to keep asleep either.
 */
internal class PersonUseTracker {

    private var screen: ScreenState? = null
    private var locked: Boolean? = null

    @Synchronized
    fun note(state: DeviceState): List<PersonUse> {
        val uses = ArrayList<PersonUse>(2)
        if (!state.locked && locked != false) uses.add(PersonUse.UNLOCKED)
        locked = state.locked
        if (screen != null && state.screen != null && state.screen != screen) {
            uses.add(if (state.screen == ScreenState.ON) PersonUse.SCREEN_ON else PersonUse.SCREEN_OFF)
        }
        if (state.screen != null) screen = state.screen
        return uses
    }
}
