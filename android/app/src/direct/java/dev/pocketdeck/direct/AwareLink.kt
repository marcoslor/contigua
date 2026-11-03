package dev.pocketdeck.direct

/**
 * The phone's Wi-Fi Aware machine (docs/design/direct-link.md §8.1, transport
 * DIRECT-1/7/12/14): one instance per paired Mac whose key it publishes.
 *
 * Off → Attaching → Publishing; a live session with the Mac's switch on adds
 * NdpPending → Up. A failed platform call parks it in Blocked(reason); an Aware
 * state change that removes the stack parks it in Lost until the platform comes
 * back. The machine is pure: effects are [AwareLinkAction] values and the
 * caller performs them, so every transition is a JVM test.
 *
 * `macDirectOn` is the Mac's stored `direct.enable`. It is a gate, not a session
 * fact: publishing with no session is what lets the Mac start a session on the
 * direct path (DIRECT-1), and a Mac that switched direct off must not be
 * published for.
 */
sealed interface AwareLinkState {
    data object Off : AwareLinkState
    data object Attaching : AwareLinkState
    data class Publishing(val window: Long? = null) : AwareLinkState
    data class NdpPending(val window: Long? = null) : AwareLinkState
    data class Up(val window: Long? = null) : AwareLinkState
    data object Lost : AwareLinkState
    data class Blocked(val reason: String) : AwareLinkState
}

/** The four conditions DIRECT-1 names; all four must hold to publish. */
data class AwareGates(
    val switchOn: Boolean = false,
    val permitted: Boolean = false,
    val keyStored: Boolean = false,
    val macDirectOn: Boolean = false,
) {
    val canPublish: Boolean get() = switchOn && permitted && keyStored && macDirectOn

    fun after(event: AwareLinkEvent): AwareGates = when (event) {
        AwareLinkEvent.SwitchOn -> copy(switchOn = true)
        AwareLinkEvent.SwitchOff -> copy(switchOn = false)
        is AwareLinkEvent.PermissionChanged -> copy(permitted = event.granted)
        AwareLinkEvent.PermissionDenied -> copy(permitted = false)
        AwareLinkEvent.KeyStored -> copy(keyStored = true)
        AwareLinkEvent.KeyForgotten -> copy(keyStored = false)
        is AwareLinkEvent.MacDirectEnable -> copy(macDirectOn = event.on)
        AwareLinkEvent.Attached, AwareLinkEvent.PublishStarted,
        is AwareLinkEvent.PublishFailed, is AwareLinkEvent.SessionLive,
        AwareLinkEvent.SessionEnded, is AwareLinkEvent.NdpAvailable,
        AwareLinkEvent.NdpLost, is AwareLinkEvent.AwareStateChanged,
        is AwareLinkEvent.SsiTick -> this
    }
}

sealed interface AwareLinkEvent {
    data object SwitchOn : AwareLinkEvent
    data object SwitchOff : AwareLinkEvent
    data class PermissionChanged(val granted: Boolean) : AwareLinkEvent
    data object PermissionDenied : AwareLinkEvent
    data object KeyStored : AwareLinkEvent
    data object KeyForgotten : AwareLinkEvent
    data class MacDirectEnable(val on: Boolean) : AwareLinkEvent
    data object Attached : AwareLinkEvent
    data object PublishStarted : AwareLinkEvent
    data class PublishFailed(val reason: String) : AwareLinkEvent
    data class SessionLive(val directOn: Boolean) : AwareLinkEvent
    data object SessionEnded : AwareLinkEvent
    data class NdpAvailable(val network: AwareNetwork) : AwareLinkEvent
    data object NdpLost : AwareLinkEvent
    data class AwareStateChanged(val available: Boolean) : AwareLinkEvent
    data class SsiTick(val window: Long) : AwareLinkEvent
}

/** What the caller does; side effects never run inside the transition. */
sealed interface AwareLinkAction {
    data object Attach : AwareLinkAction
    data object Detach : AwareLinkAction
    data object Publish : AwareLinkAction
    data object Unpublish : AwareLinkAction
    data class UpdateSsi(val window: Long) : AwareLinkAction
    data object StartNdp : AwareLinkAction
    data object ReleaseNetwork : AwareLinkAction
    data class StartListener(val network: AwareNetwork) : AwareLinkAction
    data object StopListener : AwareLinkAction
}

data class AwareLinkStep(val state: AwareLinkState, val actions: List<AwareLinkAction>)

/** The only reason tokens a `direct.state` may carry (docs/PROTOCOL.md). */
object AwareReason {
    const val NO_PERMISSION = "no_permission"
    const val NO_FEATURE = "no_feature"
    const val LOCATION_OFF = "location_off"
    const val AWARE_BUSY = "aware_busy"

    val ALL = setOf(NO_PERMISSION, NO_FEATURE, LOCATION_OFF, AWARE_BUSY)

    /** A platform failure becomes a closed token; anything else is `aware_busy`. */
    fun closed(reason: String?): String = if (reason in ALL) reason!! else AWARE_BUSY
}

class AwareLink(
    initial: AwareGates = AwareGates(),
    private val log: (String) -> Unit = {},
) {
    var state: AwareLinkState = AwareLinkState.Off
        private set

    private var gates = initial

    fun transition(event: AwareLinkEvent): AwareLinkStep {
        gates = gates.after(event)
        val from = state
        val step = next(from, event)
        state = step.state
        if (step.state != from) {
            log("aware: ${token(from)} --${token(event)}--> ${token(step.state)}")
        }
        return step
    }

    /** The state after [event] with no side effect; used by the controller's reporting. */
    fun stateToken(): String = token(state)

    private fun next(state: AwareLinkState, event: AwareLinkEvent): AwareLinkStep = when (state) {
        AwareLinkState.Off -> when (event) {
            AwareLinkEvent.SwitchOff -> stay()
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored,
            is AwareLinkEvent.PermissionChanged -> attachIfReady()
            is AwareLinkEvent.MacDirectEnable ->
                if (event.on) attachIfReady() else stay()
            AwareLinkEvent.PermissionDenied -> blocked(AwareReason.NO_PERMISSION, emptyList())
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) attachIfReady() else stay()
            is AwareLinkEvent.NdpAvailable -> release()
            AwareLinkEvent.Attached, AwareLinkEvent.PublishStarted,
            is AwareLinkEvent.PublishFailed, is AwareLinkEvent.SessionLive,
            AwareLinkEvent.SessionEnded, AwareLinkEvent.NdpLost,
            AwareLinkEvent.KeyForgotten, is AwareLinkEvent.SsiTick -> stay()
        }
        AwareLinkState.Attaching -> when (event) {
            AwareLinkEvent.Attached ->
                if (gates.canPublish) step(AwareLinkState.Publishing(), listOf(AwareLinkAction.Publish))
                else step(AwareLinkState.Off, listOf(AwareLinkAction.Detach))
            AwareLinkEvent.SwitchOff, AwareLinkEvent.KeyForgotten ->
                turnOff(AwareLinkAction.Detach)
            is AwareLinkEvent.MacDirectEnable ->
                if (event.on) stay() else turnOff(AwareLinkAction.Detach)
            AwareLinkEvent.PermissionDenied -> denied(AwareLinkAction.Detach)
            is AwareLinkEvent.PermissionChanged ->
                if (event.granted) attachIfReady() else denied(AwareLinkAction.Detach)
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) attachIfReady() else step(AwareLinkState.Lost, listOf(AwareLinkAction.Detach))
            is AwareLinkEvent.PublishFailed -> blocked(event.reason, listOf(AwareLinkAction.Detach))
            is AwareLinkEvent.NdpAvailable -> release()
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored, AwareLinkEvent.PublishStarted,
            is AwareLinkEvent.SessionLive, AwareLinkEvent.SessionEnded,
            AwareLinkEvent.NdpLost, is AwareLinkEvent.SsiTick -> stay()
        }
        is AwareLinkState.Publishing -> when (event) {
            is AwareLinkEvent.SessionLive ->
                if (event.directOn) step(AwareLinkState.NdpPending(state.window), listOf(AwareLinkAction.StartNdp))
                else stay()
            is AwareLinkEvent.SsiTick -> tick(state, event.window)
            is AwareLinkEvent.NdpAvailable -> release()
            AwareLinkEvent.SwitchOff, AwareLinkEvent.KeyForgotten ->
                turnOff(AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            is AwareLinkEvent.MacDirectEnable ->
                if (event.on) stay() else turnOff(AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            AwareLinkEvent.PermissionDenied -> denied(AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            is AwareLinkEvent.PermissionChanged ->
                if (event.granted) stay() else denied(AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) stay()
                else step(AwareLinkState.Lost, listOf(AwareLinkAction.Unpublish, AwareLinkAction.Detach))
            is AwareLinkEvent.PublishFailed ->
                blocked(event.reason, listOf(AwareLinkAction.Unpublish, AwareLinkAction.Detach))
            AwareLinkEvent.Attached, AwareLinkEvent.PublishStarted,
            AwareLinkEvent.SessionEnded, AwareLinkEvent.NdpLost,
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored -> stay()
        }
        is AwareLinkState.NdpPending -> when (event) {
            is AwareLinkEvent.NdpAvailable ->
                step(AwareLinkState.Up(state.window), listOf(AwareLinkAction.StartListener(event.network)))
            AwareLinkEvent.NdpLost -> step(AwareLinkState.Publishing(state.window), ndpRelease)
            AwareLinkEvent.SessionEnded -> step(AwareLinkState.Publishing(state.window), ndpRelease)
            is AwareLinkEvent.SessionLive ->
                if (event.directOn) stay() else step(AwareLinkState.Publishing(state.window), ndpRelease)
            is AwareLinkEvent.SsiTick -> tick(state, event.window)
            AwareLinkEvent.SwitchOff, AwareLinkEvent.KeyForgotten ->
                turnOff(AwareLinkAction.ReleaseNetwork, AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            is AwareLinkEvent.MacDirectEnable ->
                if (event.on) stay()
                else turnOff(AwareLinkAction.ReleaseNetwork, AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            AwareLinkEvent.PermissionDenied ->
                denied(AwareLinkAction.ReleaseNetwork, AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            is AwareLinkEvent.PermissionChanged ->
                if (event.granted) stay()
                else denied(AwareLinkAction.ReleaseNetwork, AwareLinkAction.Unpublish, AwareLinkAction.Detach)
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) stay()
                else step(
                    AwareLinkState.Lost,
                    listOf(AwareLinkAction.ReleaseNetwork, AwareLinkAction.Unpublish, AwareLinkAction.Detach),
                )
            is AwareLinkEvent.PublishFailed -> blocked(
                event.reason,
                listOf(AwareLinkAction.ReleaseNetwork, AwareLinkAction.Unpublish, AwareLinkAction.Detach),
            )
            AwareLinkEvent.Attached, AwareLinkEvent.PublishStarted,
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored -> stay()
        }
        is AwareLinkState.Up -> when (event) {
            AwareLinkEvent.NdpLost, AwareLinkEvent.SessionEnded ->
                step(AwareLinkState.Publishing(state.window), upRelease)
            is AwareLinkEvent.SessionLive ->
                if (event.directOn) stay() else step(AwareLinkState.Publishing(state.window), upRelease)
            is AwareLinkEvent.SsiTick -> tick(state, event.window)
            is AwareLinkEvent.NdpAvailable -> release()
            AwareLinkEvent.SwitchOff, AwareLinkEvent.KeyForgotten ->
                turnOff(
                    AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                    AwareLinkAction.Unpublish, AwareLinkAction.Detach,
                )
            is AwareLinkEvent.MacDirectEnable ->
                if (event.on) stay()
                else turnOff(
                    AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                    AwareLinkAction.Unpublish, AwareLinkAction.Detach,
                )
            AwareLinkEvent.PermissionDenied -> denied(
                AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                AwareLinkAction.Unpublish, AwareLinkAction.Detach,
            )
            is AwareLinkEvent.PermissionChanged ->
                if (event.granted) stay()
                else denied(
                    AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                    AwareLinkAction.Unpublish, AwareLinkAction.Detach,
                )
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) stay()
                else step(
                    AwareLinkState.Lost,
                    listOf(
                        AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                        AwareLinkAction.Unpublish, AwareLinkAction.Detach,
                    ),
                )
            is AwareLinkEvent.PublishFailed -> blocked(
                event.reason,
                listOf(
                    AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                    AwareLinkAction.Unpublish, AwareLinkAction.Detach,
                ),
            )
            AwareLinkEvent.Attached, AwareLinkEvent.PublishStarted,
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored -> stay()
        }
        AwareLinkState.Lost -> when (event) {
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) attachIfReady() else stay()
            AwareLinkEvent.SwitchOff, AwareLinkEvent.KeyForgotten -> turnOff()
            is AwareLinkEvent.MacDirectEnable -> if (event.on) stay() else turnOff()
            AwareLinkEvent.PermissionDenied -> blocked(AwareReason.NO_PERMISSION, emptyList())
            is AwareLinkEvent.PermissionChanged ->
                if (event.granted) attachIfReady() else blocked(AwareReason.NO_PERMISSION, emptyList())
            is AwareLinkEvent.NdpAvailable -> release()
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored, AwareLinkEvent.Attached,
            AwareLinkEvent.PublishStarted, is AwareLinkEvent.PublishFailed,
            is AwareLinkEvent.SessionLive, AwareLinkEvent.SessionEnded,
            AwareLinkEvent.NdpLost, is AwareLinkEvent.SsiTick -> stay()
        }
        is AwareLinkState.Blocked -> when (event) {
            AwareLinkEvent.SwitchOff, AwareLinkEvent.KeyForgotten -> turnOff()
            is AwareLinkEvent.MacDirectEnable -> if (event.on) attachIfReady() else turnOff()
            is AwareLinkEvent.NdpAvailable -> release()
            AwareLinkEvent.SwitchOn, AwareLinkEvent.KeyStored,
            is AwareLinkEvent.PermissionChanged -> attachIfReady()
            AwareLinkEvent.PermissionDenied -> blocked(AwareReason.NO_PERMISSION, emptyList())
            is AwareLinkEvent.AwareStateChanged ->
                if (event.available) attachIfReady() else stay()
            AwareLinkEvent.Attached, AwareLinkEvent.PublishStarted,
            is AwareLinkEvent.PublishFailed, is AwareLinkEvent.SessionLive,
            AwareLinkEvent.SessionEnded, AwareLinkEvent.NdpLost,
            is AwareLinkEvent.SsiTick -> stay()
        }
    }

    private fun tick(state: AwareLinkState, window: Long): AwareLinkStep {
        val current = when (state) {
            is AwareLinkState.Publishing -> state.window
            is AwareLinkState.NdpPending -> state.window
            is AwareLinkState.Up -> state.window
            else -> null
        }
        if (current == window) return AwareLinkStep(state, emptyList())
        val next = when (state) {
            is AwareLinkState.Publishing -> state.copy(window = window)
            is AwareLinkState.NdpPending -> state.copy(window = window)
            is AwareLinkState.Up -> state.copy(window = window)
            else -> state
        }
        return AwareLinkStep(next, listOf(AwareLinkAction.UpdateSsi(window)))
    }

    private fun attachIfReady(): AwareLinkStep =
        if (gates.canPublish) step(AwareLinkState.Attaching, listOf(AwareLinkAction.Attach)) else stay()

    private fun turnOff(vararg actions: AwareLinkAction): AwareLinkStep =
        step(AwareLinkState.Off, actions.toList())

    private fun denied(vararg actions: AwareLinkAction): AwareLinkStep =
        blocked(AwareReason.NO_PERMISSION, actions.toList())

    private fun blocked(reason: String, actions: List<AwareLinkAction>): AwareLinkStep =
        step(AwareLinkState.Blocked(AwareReason.closed(reason)), actions)

    private fun release(): AwareLinkStep =
        AwareLinkStep(state, listOf(AwareLinkAction.ReleaseNetwork))

    private fun stay(): AwareLinkStep = AwareLinkStep(state, emptyList())

    private fun step(state: AwareLinkState, actions: List<AwareLinkAction>): AwareLinkStep =
        AwareLinkStep(state, actions)

    private companion object {
        val ndpRelease = listOf(AwareLinkAction.ReleaseNetwork)
        val upRelease = listOf(AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener)

        fun token(state: AwareLinkState): String = when (state) {
            AwareLinkState.Off -> "off"
            AwareLinkState.Attaching -> "attaching"
            is AwareLinkState.Publishing -> "publishing"
            is AwareLinkState.NdpPending -> "ndp_pending"
            is AwareLinkState.Up -> "up"
            AwareLinkState.Lost -> "lost"
            is AwareLinkState.Blocked -> "blocked:${state.reason}"
        }

        fun token(event: AwareLinkEvent): String = when (event) {
            AwareLinkEvent.SwitchOn -> "switch_on"
            AwareLinkEvent.SwitchOff -> "switch_off"
            is AwareLinkEvent.PermissionChanged -> if (event.granted) "permission:on" else "permission:off"
            AwareLinkEvent.PermissionDenied -> "permission_denied"
            AwareLinkEvent.KeyStored -> "key_stored"
            AwareLinkEvent.KeyForgotten -> "key_forgotten"
            is AwareLinkEvent.MacDirectEnable -> if (event.on) "mac:on" else "mac:off"
            AwareLinkEvent.Attached -> "attached"
            AwareLinkEvent.PublishStarted -> "publish_started"
            is AwareLinkEvent.PublishFailed -> "publish_failed:${AwareReason.closed(event.reason)}"
            is AwareLinkEvent.SessionLive -> "connected"
            AwareLinkEvent.SessionEnded -> "disconnected"
            is AwareLinkEvent.NdpAvailable -> "ndp_available"
            AwareLinkEvent.NdpLost -> "ndp_lost"
            is AwareLinkEvent.AwareStateChanged -> if (event.available) "aware:on" else "aware:off"
            is AwareLinkEvent.SsiTick -> "ssi_tick"
        }
    }
}
