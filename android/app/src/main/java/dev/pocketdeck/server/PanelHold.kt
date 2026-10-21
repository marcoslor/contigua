package dev.pocketdeck.server

/**
 * "Turn Off Phone Screen" (docs/design/phone-mirror.md): the person's Mac asks
 * the phone to keep its own panel dark while the phone window keeps rendering.
 * It is one hold with a life of its own — requested, applied, paused with the
 * window, ended by the person or the session — so it is one explicit state
 * machine: [PanelHoldState] plus the pure [panelHoldTransition].
 *
 * The transition never touches the platform: it returns [PanelHoldAction]s and
 * the caller performs them. `state.panel` is derived from [PanelHoldModel.holdsPanel]
 * and from nothing else.
 */
internal enum class PanelHoldState {
    /** No hold: the panel is the platform's. */
    Off,

    /** The request is applied; the take-over is still settling. */
    Applying,

    /** The panel is held dark while the phone window renders. */
    Held,

    /** Requested, but the phone window is paused: the panel is normal until it resumes. */
    Suspended,

    /** The hold has ended and the panel is being handed back. */
    Restoring,
}

/** The phone window's visibility, as the session reports it. */
internal enum class PanelMirror { Closed, Open, Paused }

internal sealed interface PanelHoldEvent {
    val wire: String

    /** `phone.panel {off: true}`; [ignorePower] is the Mac's "keep it off" setting. */
    data class RequestOff(val ignorePower: Boolean = false) : PanelHoldEvent {
        override val wire: String get() = "requestOff"
    }

    /** `phone.panel {off: false}`. */
    data object RequestOn : PanelHoldEvent {
        override val wire: String get() = "requestOn"
    }

    data object WindowOpened : PanelHoldEvent {
        override val wire: String get() = "windowOpened"
    }

    data object WindowPaused : PanelHoldEvent {
        override val wire: String get() = "windowPaused"
    }

    data object WindowResumed : PanelHoldEvent {
        override val wire: String get() = "windowResumed"
    }

    data object WindowClosed : PanelHoldEvent {
        override val wire: String get() = "windowClosed"
    }

    /** One keep-alive step with the platform's reading of display 0. */
    data class KeepAliveStep(val panelOn: Boolean) : PanelHoldEvent {
        override val wire: String get() = "keepAlive"
    }

    /** The person pressed the phone's power button while the panel was held. */
    data object PowerPress : PanelHoldEvent {
        override val wire: String get() = "powerPress"
    }

    data object SessionEnded : PanelHoldEvent {
        override val wire: String get() = "sessionEnded"
    }

    /** The server started and found a crash marker: the panel may be left dark. */
    data object CrashRecovery : PanelHoldEvent {
        override val wire: String get() = "crashRecovery"
    }

    /** [PanelHoldState.Restoring] finished: the panel is the platform's again. */
    data object RestoreDone : PanelHoldEvent {
        override val wire: String get() = "restoreDone"
    }
}

internal sealed interface PanelHoldAction {
    /** Write SurfaceFlinger's power mode OFF; [transitional] re-applies after the wake settles. */
    data class PanelOff(val transitional: Boolean) : PanelHoldAction

    /** Give the panel back; [wake] first waits for the platform's own screen-off (a power press). */
    data class PanelNormal(val wake: Boolean = false) : PanelHoldAction

    data object StartKeepAlive : PanelHoldAction

    data object StopKeepAlive : PanelHoldAction

    /** `state.panel`: the truth the Mac draws. */
    data class ReportPanel(val off: Boolean) : PanelHoldAction
}

internal data class PanelHoldModel(
    val state: PanelHoldState = PanelHoldState.Off,
    val mirror: PanelMirror = PanelMirror.Closed,
    val ignorePower: Boolean = false,
) {
    /** True while the panel is ours: the only source of `state.panel off`. */
    val holdsPanel: Boolean get() = state == PanelHoldState.Applying || state == PanelHoldState.Held
}

internal data class PanelHoldTransition(val model: PanelHoldModel, val actions: List<PanelHoldAction>)

/**
 * The one pure rule. Every state accepts every event, including the ones it
 * ignores, and nothing here touches the platform: the caller performs the
 * actions. The invariant is structural — every exit from [Applying]/[Held]
 * carries [PanelHoldAction.PanelNormal] — and [PanelHoldTest] checks it for
 * every pair.
 *
 * A paused phone window suspends the hold instead of ending it: the panel is
 * handed back (nobody is watching a paused mirror), the request stays, and the
 * next resume applies it again. A power press ends the hold unless the Mac's
 * "keep it off" setting is on; then the hold stands and the next keep-alive
 * step re-applies the panel off.
 */
internal fun panelHoldTransition(model: PanelHoldModel, event: PanelHoldEvent): PanelHoldTransition {
    val open = model.mirror == PanelMirror.Open

    fun apply(mirror: PanelMirror = PanelMirror.Open, ignore: Boolean = model.ignorePower) = PanelHoldTransition(
        model.copy(state = PanelHoldState.Applying, mirror = mirror, ignorePower = ignore),
        listOf(PanelHoldAction.PanelOff(true), PanelHoldAction.StartKeepAlive, PanelHoldAction.ReportPanel(true)),
    )

    fun suspend() = PanelHoldTransition(
        model.copy(state = PanelHoldState.Suspended, mirror = PanelMirror.Paused),
        listOf(PanelHoldAction.PanelNormal(), PanelHoldAction.StopKeepAlive, PanelHoldAction.ReportPanel(false)),
    )

    fun restore(mirror: PanelMirror = model.mirror, wake: Boolean = false) = PanelHoldTransition(
        model.copy(state = PanelHoldState.Restoring, mirror = mirror),
        listOf(PanelHoldAction.PanelNormal(wake), PanelHoldAction.StopKeepAlive, PanelHoldAction.ReportPanel(false)),
    )

    fun ignored() = PanelHoldTransition(model, emptyList())

    return when (model.state) {
        PanelHoldState.Off -> when (event) {
            // With no phone window the request is only remembered.
            is PanelHoldEvent.RequestOff -> if (open) apply(ignore = event.ignorePower)
                else PanelHoldTransition(model.copy(state = PanelHoldState.Suspended, ignorePower = event.ignorePower),
                    emptyList())
            PanelHoldEvent.RequestOn -> ignored()
            PanelHoldEvent.WindowOpened, PanelHoldEvent.WindowResumed ->
                PanelHoldTransition(model.copy(mirror = PanelMirror.Open), emptyList())
            PanelHoldEvent.WindowPaused -> PanelHoldTransition(model.copy(mirror = PanelMirror.Paused), emptyList())
            PanelHoldEvent.WindowClosed -> PanelHoldTransition(model.copy(mirror = PanelMirror.Closed), emptyList())
            is PanelHoldEvent.KeepAliveStep -> ignored()
            PanelHoldEvent.PowerPress -> ignored()
            PanelHoldEvent.SessionEnded -> PanelHoldTransition(model.copy(mirror = PanelMirror.Closed), emptyList())
            // A crash left the panel forced off: hand it back, never adopt it.
            PanelHoldEvent.CrashRecovery -> PanelHoldTransition(
                model.copy(state = PanelHoldState.Restoring),
                listOf(PanelHoldAction.PanelNormal(), PanelHoldAction.StopKeepAlive),
            )
            PanelHoldEvent.RestoreDone -> ignored()
        }

        PanelHoldState.Applying -> when (event) {
            is PanelHoldEvent.RequestOff -> PanelHoldTransition(model.copy(ignorePower = event.ignorePower), emptyList())
            PanelHoldEvent.RequestOn -> restore()
            PanelHoldEvent.WindowOpened, PanelHoldEvent.WindowResumed ->
                PanelHoldTransition(model.copy(mirror = PanelMirror.Open), emptyList())
            PanelHoldEvent.WindowPaused -> suspend()
            PanelHoldEvent.WindowClosed -> restore(mirror = PanelMirror.Closed)
            is PanelHoldEvent.KeepAliveStep -> PanelHoldTransition(
                model.copy(state = PanelHoldState.Held),
                if (event.panelOn) listOf(PanelHoldAction.PanelOff(false)) else emptyList(),
            )
            PanelHoldEvent.PowerPress -> if (model.ignorePower) {
                PanelHoldTransition(model.copy(state = PanelHoldState.Held), emptyList())
            } else {
                restore(wake = true)
            }
            PanelHoldEvent.SessionEnded -> restore(mirror = PanelMirror.Closed)
            PanelHoldEvent.CrashRecovery -> ignored()
            PanelHoldEvent.RestoreDone -> ignored()
        }

        PanelHoldState.Held -> when (event) {
            is PanelHoldEvent.RequestOff -> PanelHoldTransition(model.copy(ignorePower = event.ignorePower), emptyList())
            PanelHoldEvent.RequestOn -> restore()
            PanelHoldEvent.WindowOpened, PanelHoldEvent.WindowResumed ->
                PanelHoldTransition(model.copy(mirror = PanelMirror.Open), emptyList())
            PanelHoldEvent.WindowPaused -> suspend()
            PanelHoldEvent.WindowClosed -> restore(mirror = PanelMirror.Closed)
            // Re-asserted whenever the platform reads the panel as on: that is
            // its belief while only the power mode is ours, and also what a
            // platform write of its own looks like.
            is PanelHoldEvent.KeepAliveStep -> PanelHoldTransition(
                model,
                if (event.panelOn) listOf(PanelHoldAction.PanelOff(false)) else emptyList(),
            )
            PanelHoldEvent.PowerPress -> if (model.ignorePower) ignored() else restore(wake = true)
            PanelHoldEvent.SessionEnded -> restore(mirror = PanelMirror.Closed)
            PanelHoldEvent.CrashRecovery -> ignored()
            PanelHoldEvent.RestoreDone -> ignored()
        }

        PanelHoldState.Suspended -> when (event) {
            is PanelHoldEvent.RequestOff -> PanelHoldTransition(model.copy(ignorePower = event.ignorePower), emptyList())
            PanelHoldEvent.RequestOn -> PanelHoldTransition(model.copy(state = PanelHoldState.Off), emptyList())
            PanelHoldEvent.WindowOpened, PanelHoldEvent.WindowResumed -> apply()
            PanelHoldEvent.WindowPaused -> PanelHoldTransition(model.copy(mirror = PanelMirror.Paused), emptyList())
            PanelHoldEvent.WindowClosed ->
                PanelHoldTransition(model.copy(state = PanelHoldState.Off, mirror = PanelMirror.Closed), emptyList())
            is PanelHoldEvent.KeepAliveStep -> ignored()
            PanelHoldEvent.PowerPress -> ignored()
            PanelHoldEvent.SessionEnded ->
                PanelHoldTransition(model.copy(state = PanelHoldState.Off, mirror = PanelMirror.Closed), emptyList())
            PanelHoldEvent.CrashRecovery -> ignored()
            PanelHoldEvent.RestoreDone -> ignored()
        }

        PanelHoldState.Restoring -> when (event) {
            is PanelHoldEvent.RequestOff -> if (open) apply(ignore = event.ignorePower)
                else PanelHoldTransition(model.copy(state = PanelHoldState.Suspended, ignorePower = event.ignorePower),
                    emptyList())
            PanelHoldEvent.RequestOn -> PanelHoldTransition(model.copy(state = PanelHoldState.Off), emptyList())
            PanelHoldEvent.WindowOpened, PanelHoldEvent.WindowResumed ->
                PanelHoldTransition(model.copy(mirror = PanelMirror.Open), emptyList())
            PanelHoldEvent.WindowPaused -> PanelHoldTransition(model.copy(mirror = PanelMirror.Paused), emptyList())
            PanelHoldEvent.WindowClosed -> PanelHoldTransition(model.copy(mirror = PanelMirror.Closed), emptyList())
            is PanelHoldEvent.KeepAliveStep -> ignored()
            PanelHoldEvent.PowerPress -> ignored()
            PanelHoldEvent.SessionEnded -> PanelHoldTransition(model.copy(mirror = PanelMirror.Closed), emptyList())
            PanelHoldEvent.CrashRecovery -> ignored()
            PanelHoldEvent.RestoreDone -> PanelHoldTransition(model.copy(state = PanelHoldState.Off), emptyList())
        }
    }
}

/**
 * The live machine: keeps the model, logs every transition, returns the actions
 * for the caller to perform.
 */
internal class PanelHoldMachine(private val log: (String) -> Unit = {}) {

    private var model = PanelHoldModel()

    val state: PanelHoldState get() = model.state
    val holdsPanel: Boolean get() = model.holdsPanel
    val mirror: PanelMirror get() = model.mirror
    val mirrorOpen: Boolean get() = model.mirror == PanelMirror.Open
    val ignorePower: Boolean get() = model.ignorePower

    fun dispatch(event: PanelHoldEvent): List<PanelHoldAction> {
        val before = model
        val transition = panelHoldTransition(before, event)
        model = transition.model
        if (before.state != model.state || event !is PanelHoldEvent.KeepAliveStep) {
            log("panelhold: ${before.state} --${event.wire}--> ${model.state}")
        }
        return transition.actions
    }
}
