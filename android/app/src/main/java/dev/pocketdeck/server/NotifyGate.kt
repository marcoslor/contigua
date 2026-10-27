package dev.pocketdeck.server

/**
 * The notification gate (docs/design/notify.md, docs/specs/settings-devices.md
 * SET-DEV-09). The Mac's per-phone `notify.enable` is the only person-facing
 * switch; the phone's notification-listener grant decides whether it can be
 * honoured. A missing grant while the Mac asked is `NO_ACCESS`, which the Mac
 * shows as "Allow notification access on the phone" and the phone shows as an
 * attention item.
 */
enum class NotifyGate { OFF, FORWARDING, NO_ACCESS }

fun notifyGate(macOn: Boolean, listenerGranted: Boolean): NotifyGate = when {
    !macOn -> NotifyGate.OFF
    listenerGranted -> NotifyGate.FORWARDING
    else -> NotifyGate.NO_ACCESS
}

/** `notify.state`: `on` says forwarding is live; `reason` only explains a refusal. */
fun notifyStateMessage(gate: NotifyGate): Map<String, Any?> {
    val message = linkedMapOf<String, Any?>(
        "t" to "notify.state",
        "on" to (gate == NotifyGate.FORWARDING),
    )
    if (gate == NotifyGate.NO_ACCESS) message["reason"] = "no_access"
    return message
}

/** The phone's home needs a way to fix the grant only in this case. */
fun needsNotificationAccessAttention(gate: NotifyGate): Boolean = gate == NotifyGate.NO_ACCESS
