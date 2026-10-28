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

// ---------------------------------------------------------------------------
// The panel's own input devices (docs/specs/controls.md CTRL-11).
//
// A `state` emission says nothing about a touch on an unlocked phone: a finger
// on display 0 changes no lock, screen or battery value. The phone's raw input
// devices do say it, and they are the only place that separates the person from
// us: our keep-alive pokes are `IPowerManager.userActivity` calls and injected
// session input is `InputManager.injectInputEvent`, so neither ever reaches the
// kernel device nodes, while every finger and key press on the panel does.
// ---------------------------------------------------------------------------

/** One thing the person did on the panel, as a closed set. */
internal enum class PanelInput {
    /** A finger went down on display 0's touchscreen. */
    TOUCH,

    /** A key that is not the power key. */
    KEY,

    /** The power key: the power watch's own edge decides that one. */
    POWER,
}

/** One decoded `struct input_event`. */
internal data class RawInputEvent(val type: Int, val code: Int, val value: Int)

/** One `/dev/input` node, with the device's kernel name for the log. */
internal data class InputEventNode(val path: String, val name: String)

/** `EV_KEY` / `EV_ABS` from `<linux/input-event-codes.h>`. */
private const val EV_KEY = 0x01
private const val EV_ABS = 0x03

private const val ABS_MT_TRACKING_ID = 0x39
private const val BTN_TOOL_FINGER = 0x145
private const val BTN_TOUCH = 0x14a

/** `KEY_POWER`, `KEY_SLEEP`, `KEY_WAKEUP`: the power watch already sees these. */
private val POWER_KEY_CODES = setOf(116, 142, 143)

/** `BTN_TOOL_*`: an S-Pen or a mouse hovering is not a finger on the panel. */
private val TOOL_KEY_CODES = (0x140..0x149).toSet()

/** Bytes in one `struct input_event` on this ABI (timeval + type + code + value). */
internal val INPUT_EVENT_BYTES: Int = 2 * Long.SIZE_BYTES + 8

/**
 * What one input event means for the panel: a finger, a key, the power key, or
 * nothing (a release, a pen tool, a sync). Pure, so the JVM tests drive it.
 */
internal fun panelInput(type: Int, code: Int, value: Int): PanelInput? = when {
    // A new contact, not the -1 that ends one.
    type == EV_ABS -> if (code == ABS_MT_TRACKING_ID && value >= 0) PanelInput.TOUCH else null
    type != EV_KEY || value == 0 -> null
    code == BTN_TOUCH || code == BTN_TOOL_FINGER -> PanelInput.TOUCH
    code in POWER_KEY_CODES -> PanelInput.POWER
    code in TOOL_KEY_CODES -> null
    else -> PanelInput.KEY
}

/** `/proc/bus/input/devices` -> one `/dev/input/eventN` per input device. */
internal fun inputEventNodes(text: String): List<InputEventNode> {
    val nodes = ArrayList<InputEventNode>()
    var name = ""
    for (raw in text.lineSequence()) {
        val line = raw.trim()
        when {
            line.startsWith("N: Name=") -> name = line.removePrefix("N: Name=").trim('"')
            line.startsWith("H: Handlers=") -> {
                for (handler in line.removePrefix("H: Handlers=").split(' ')) {
                    if (handler.startsWith("event")) nodes.add(InputEventNode("/dev/input/$handler", name))
                }
            }
        }
    }
    return nodes
}

/** One little-endian `struct input_event` at [offset]. */
internal fun decodeInputEvent(bytes: ByteArray, offset: Int = 0): RawInputEvent {
    val typeAt = offset + 2 * Long.SIZE_BYTES
    fun u16(at: Int): Int = (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8)
    fun s32(at: Int): Int =
        (bytes[at].toInt() and 0xFF) or
            ((bytes[at + 1].toInt() and 0xFF) shl 8) or
            ((bytes[at + 2].toInt() and 0xFF) shl 16) or
            (bytes[at + 3].toInt() shl 24)
    return RawInputEvent(type = u16(typeAt), code = u16(typeAt + 2), value = s32(typeAt + 4))
}
