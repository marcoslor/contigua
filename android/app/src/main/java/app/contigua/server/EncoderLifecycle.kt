package app.contigua.server

/**
 * One window stream's encoder and display lifetime, as an explicit machine.
 *
 * The stream used to carry this as independent fields (`prepared`, `previous`,
 * `encoder`, `paused`, `released`, `encoderSuspended`, `persistent`): a built
 * encoder waiting for the display, the one the display no longer feeds, and the
 * attached one were three codec slots with no name, so no log said which state a
 * stream was in. Here the phases are closed, the events are the calls the session
 * makes, and the pure [encoderTransition] returns the calls the stream performs;
 * nothing in the transition touches a codec or a display.
 *
 * [phase] is the slot's state; `paused` and `suspended` are the two input
 * controls the protocol has (a covered window drops output; the send queue stops
 * encoder input), and either can arrive while the other is on, so they stay
 * qualifiers of an attached encoder instead of more phases.
 */
enum class EncoderPhase {
    /** No encoder and no display work in flight. */
    Empty,

    /** An open is building/starting its first encoder; the display does not exist yet. */
    Opening,

    /** A prepared encoder waits: the display is about to be created, or a resize built one. */
    Prepared,

    /** An encoder is attached and draining; `paused`/`suspended` say how it is held. */
    Attached,

    /** The old encoder is gone: the prepared one is being started or rebuilt before it attaches. */
    Swapping,

    /** The stream closed: every slot and the display are released. */
    Released,
}

enum class DisplayPhase(val wire: String) {
    None("none"),
    Mirror("mirror"),
    Virtual("virtual"),
}

internal data class EncoderState(
    val phase: EncoderPhase = EncoderPhase.Empty,
    /** The Mac covered the window: the encoder keeps running, its output is dropped. */
    val paused: Boolean = false,
    /** Q1 stopped encoder input at the surface (the send queue's budget). */
    val suspended: Boolean = false,
    /** The display keeps one shared input surface for its life. */
    val persistent: Boolean = false,
    /** A built encoder waits in the prepared slot. */
    val prepared: Boolean = false,
    /** The prepared encoder started on its own input surface (it must not be started again). */
    val preparedStarted: Boolean = false,
    /** The encoder the display no longer feeds waits to be released. */
    val previous: Boolean = false,
    val display: DisplayPhase = DisplayPhase.None,
    /** The display an open is building: Mirror or Virtual until `Created` moves it to [display]. */
    val pendingDisplay: DisplayPhase = DisplayPhase.None,
) {
    val released: Boolean get() = phase == EncoderPhase.Released
}

internal sealed interface EncoderEvent {
    /** The event's token in `encoder: <from> --<event>--> <to>`. */
    val wire: String

    /** `start`/`startMirror`: create the display with a first encoder. */
    data class Open(val display: DisplayPhase, val size: IntSize) : EncoderEvent {
        override val wire: String get() = "open"
    }

    /** The shared input surface ask finished; false when the platform refused it. */
    data class SurfaceReady(val persistent: Boolean) : EncoderEvent {
        override val wire: String get() = "surface"
    }

    /**
     * A build finished. [started] is true when the codec already has its own
     * input surface and is running; [attach] asks the same plan to attach it
     * (a swap's fallback rebuild) instead of leaving it to the sequencer.
     */
    data class Built(val started: Boolean, val attach: Boolean = false) : EncoderEvent {
        override val wire: String get() = "built"
    }

    data object BuildFailed : EncoderEvent {
        override val wire: String get() = "build-failed"
    }

    /** `startOnPersistent` accepted the codec. */
    data object Started : EncoderEvent {
        override val wire: String get() = "started"
    }

    /** `startOnPersistent` refused it; [size] is the size to rebuild at. */
    data class StartRefused(val size: IntSize) : EncoderEvent {
        override val wire: String get() = "start-refused"
    }

    /** The display exists and points at the prepared encoder's surface. */
    data object Created : EncoderEvent {
        override val wire: String get() = "created"
    }

    /** A resize/resume asks for the next encoder; false on failure leaves the stream as it was. */
    data class Prepare(val size: IntSize) : EncoderEvent {
        override val wire: String get() = "prepare"
    }

    /** The sequencer wants the prepared encoder attached. */
    data object Attach : EncoderEvent {
        override val wire: String get() = "attach"
    }

    /** The prepared encoder was swapped in beside the old one. */
    data class Swapped(val suspended: Boolean, val previous: Boolean) : EncoderEvent {
        override val wire: String get() = "swapped"
    }

    /** The prepared encoder attached after a detach/rebuild. */
    data class Installed(val suspended: Boolean) : EncoderEvent {
        override val wire: String get() = "installed"
    }

    data object Pause : EncoderEvent {
        override val wire: String get() = "pause"
    }

    data object Resume : EncoderEvent {
        override val wire: String get() = "resume"
    }

    data class Suspend(val suspended: Boolean) : EncoderEvent {
        override val wire: String get() = if (suspended) "suspend" else "resume-input"
    }

    /** The encoder accepted or refused `PARAMETER_KEY_SUSPEND`. */
    data class SuspendApplied(val suspended: Boolean, val applied: Boolean) : EncoderEvent {
        override val wire: String get() = if (suspended) "suspend" else "resume-input"
    }

    data object ReleasePrevious : EncoderEvent {
        override val wire: String get() = "release-previous"
    }

    data object Release : EncoderEvent {
        override val wire: String get() = "release"
    }
}

/** The calls [encoderTransition] returns; the stream performs them in order. */
internal sealed interface EncoderAction {
    data object CreateSurface : EncoderAction

    /** Configure a codec for [size] into the prepared slot; [attach] continues a swap. */
    data class Build(val size: IntSize, val attach: Boolean = false) : EncoderAction

    /** Attach the prepared codec to the shared surface and start it. */
    data object StartPrepared : EncoderAction

    /** Release the shared surface and continue on the encoder's own surface. */
    data object DropSurface : EncoderAction

    /** Create the display of [display] at the current size and density. */
    data class CreateDisplay(val display: DisplayPhase) : EncoderAction

    /** Point the new display at the prepared codec (the open path). */
    data object AttachFresh : EncoderAction

    /** Attach a started/restarted codec; [persistent] keeps the display on the shared surface. */
    data class Attach(val persistent: Boolean) : EncoderAction

    /** Swap the prepared encoder in; the old one is released after the switch. */
    data object Swap : EncoderAction

    /** Stop and release the old encoder before the shared surface can take the new one. */
    data object DetachOld : EncoderAction

    data object Detach : EncoderAction
    data object ReleasePrepared : EncoderAction
    data object ReleasePreviousCodec : EncoderAction
    data object ReleaseDisplay : EncoderAction
    data object ReleaseSurface : EncoderAction

    /** Resume with the encoder kept: re-send the codec config, ask for a key, nudge an idle app. */
    data object ResendConfig : EncoderAction
    data object RequestKey : EncoderAction
    data object Nudge : EncoderAction

    /** Rebuild and attach an encoder: the pause detached it, or a failed swap left the stream empty. */
    data object Rebuild : EncoderAction

    data class ApplySuspend(val suspended: Boolean) : EncoderAction
}

internal data class EncoderTransition(
    val state: EncoderState,
    val actions: List<EncoderAction>,
)

/** The one pure rule. Every state accepts every event; an unlisted pair is ignored. */
internal fun encoderTransition(state: EncoderState, event: EncoderEvent): EncoderTransition {
    fun stay(actions: List<EncoderAction> = emptyList()) = EncoderTransition(state, actions)

    return when (event) {
        is EncoderEvent.Open -> when (state.phase) {
            EncoderPhase.Empty -> EncoderTransition(
                state.copy(phase = EncoderPhase.Opening, pendingDisplay = event.display),
                buildList {
                    if (event.display == DisplayPhase.Virtual) add(EncoderAction.CreateSurface)
                    add(EncoderAction.Build(event.size))
                },
            )
            EncoderPhase.Opening, EncoderPhase.Prepared, EncoderPhase.Attached,
            EncoderPhase.Swapping, EncoderPhase.Released -> stay()
        }

        is EncoderEvent.SurfaceReady -> when (state.phase) {
            EncoderPhase.Opening, EncoderPhase.Prepared ->
                EncoderTransition(state.copy(persistent = event.persistent), emptyList())
            EncoderPhase.Empty, EncoderPhase.Attached, EncoderPhase.Swapping,
            EncoderPhase.Released -> stay()
        }

        is EncoderEvent.Built -> when (state.phase) {
            EncoderPhase.Opening -> EncoderTransition(
                state.copy(phase = EncoderPhase.Prepared, prepared = true,
                    preparedStarted = event.started),
                if (event.started) {
                    listOf(EncoderAction.CreateDisplay(state.pendingDisplay))
                } else {
                    listOf(EncoderAction.StartPrepared)
                },
            )
            // A resize or resume built the codec; the sequencer attaches it next.
            EncoderPhase.Attached -> EncoderTransition(
                state.copy(prepared = true, preparedStarted = event.started), emptyList(),
            )
            // A pause detached the encoder (or a failed swap emptied the stream):
            // the build is the first half of a rebuild.
            EncoderPhase.Empty, EncoderPhase.Swapping -> if (event.attach) {
                EncoderTransition(
                    state.copy(phase = EncoderPhase.Swapping, prepared = true,
                        preparedStarted = event.started),
                    listOf(EncoderAction.Attach(persistent = false)),
                )
            } else {
                EncoderTransition(
                    state.copy(phase = EncoderPhase.Prepared, prepared = true,
                        preparedStarted = event.started),
                    emptyList(),
                )
            }
            EncoderPhase.Prepared, EncoderPhase.Released -> stay()
        }

        EncoderEvent.BuildFailed -> when (state.phase) {
            EncoderPhase.Opening -> EncoderTransition(
                EncoderState(phase = EncoderPhase.Empty, display = state.display),
                emptyList(),
            )
            EncoderPhase.Swapping -> EncoderTransition(
                EncoderState(phase = EncoderPhase.Empty, paused = state.paused,
                    suspended = state.suspended, display = state.display),
                emptyList(),
            )
            // The old encoder never stopped feeding the display.
            EncoderPhase.Attached -> EncoderTransition(
                state.copy(prepared = false, preparedStarted = false), emptyList(),
            )
            EncoderPhase.Empty, EncoderPhase.Prepared, EncoderPhase.Released -> stay()
        }

        EncoderEvent.Started -> when (state.phase) {
            EncoderPhase.Prepared -> EncoderTransition(
                state.copy(preparedStarted = true),
                listOf(EncoderAction.CreateDisplay(state.pendingDisplay)),
            )
            EncoderPhase.Swapping -> EncoderTransition(
                state.copy(preparedStarted = true),
                listOf(EncoderAction.Attach(persistent = true)),
            )
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Attached,
            EncoderPhase.Released -> stay()
        }

        is EncoderEvent.StartRefused -> when (state.phase) {
            // The refused codec is already released; rebuild on its own surface
            // and carry on creating the display.
            EncoderPhase.Prepared -> EncoderTransition(
                state.copy(phase = EncoderPhase.Opening, persistent = false,
                    prepared = false, preparedStarted = false),
                listOf(EncoderAction.DropSurface, EncoderAction.Build(event.size)),
            )
            // Mid-swap: the rebuild must attach within this plan, not wait for
            // the sequencer (which already called attach once).
            EncoderPhase.Swapping -> EncoderTransition(
                state.copy(persistent = false, prepared = false, preparedStarted = false),
                listOf(EncoderAction.DropSurface, EncoderAction.Build(event.size, attach = true)),
            )
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Attached,
            EncoderPhase.Released -> stay()
        }

        EncoderEvent.Created -> when (state.phase) {
            EncoderPhase.Prepared -> EncoderTransition(
                state.copy(phase = EncoderPhase.Attached, display = state.pendingDisplay,
                    pendingDisplay = DisplayPhase.None),
                listOf(EncoderAction.AttachFresh),
            )
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Attached,
            EncoderPhase.Swapping, EncoderPhase.Released -> stay()
        }

        is EncoderEvent.Prepare -> when (state.phase) {
            EncoderPhase.Attached -> if (state.prepared) {
                stay()
            } else {
                EncoderTransition(state, listOf(EncoderAction.Build(event.size)))
            }
            EncoderPhase.Swapping, EncoderPhase.Empty ->
                if (state.prepared || state.display == DisplayPhase.None || state.paused) {
                    stay()
                } else {
                    EncoderTransition(state, listOf(EncoderAction.Build(event.size)))
                }
            EncoderPhase.Opening, EncoderPhase.Prepared, EncoderPhase.Released -> stay()
        }

        EncoderEvent.Attach -> when (state.phase) {
            EncoderPhase.Attached -> when {
                !state.prepared -> stay()
                state.preparedStarted -> EncoderTransition(state, listOf(EncoderAction.Swap))
                else -> EncoderTransition(
                    state.copy(phase = EncoderPhase.Swapping),
                    listOf(EncoderAction.DetachOld, EncoderAction.StartPrepared),
                )
            }
            // The display already exists: a rebuild or resume's prepared codec
            // is swapped in with no old encoder to release.
            EncoderPhase.Prepared -> when {
                state.display == DisplayPhase.None || !state.prepared -> stay()
                state.preparedStarted -> EncoderTransition(
                    state.copy(phase = EncoderPhase.Attached),
                    listOf(EncoderAction.Swap),
                )
                else -> EncoderTransition(
                    state.copy(phase = EncoderPhase.Swapping),
                    listOf(EncoderAction.DetachOld, EncoderAction.StartPrepared),
                )
            }
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Swapping,
            EncoderPhase.Released -> stay()
        }

        is EncoderEvent.Swapped -> when (state.phase) {
            EncoderPhase.Attached, EncoderPhase.Swapping -> EncoderTransition(
                state.copy(phase = EncoderPhase.Attached, prepared = false,
                    preparedStarted = false, previous = event.previous,
                    suspended = event.suspended),
                emptyList(),
            )
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Prepared,
            EncoderPhase.Released -> stay()
        }

        is EncoderEvent.Installed -> when (state.phase) {
            EncoderPhase.Attached, EncoderPhase.Swapping -> EncoderTransition(
                state.copy(phase = EncoderPhase.Attached, prepared = false,
                    preparedStarted = false, previous = false,
                    suspended = event.suspended),
                emptyList(),
            )
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Prepared,
            EncoderPhase.Released -> stay()
        }

        EncoderEvent.Pause -> when (state.phase) {
            EncoderPhase.Attached -> if (state.paused) {
                stay()
            } else {
                EncoderTransition(
                    state.copy(paused = true),
                    if (state.persistent) emptyList() else listOf(EncoderAction.Detach),
                )
            }
            // A failed swap left a display with no encoder: pausing still
            // stops output and a resume rebuilds.
            EncoderPhase.Empty -> if (state.paused || state.display == DisplayPhase.None) {
                stay()
            } else {
                EncoderTransition(state.copy(paused = true), emptyList())
            }
            EncoderPhase.Opening, EncoderPhase.Prepared, EncoderPhase.Swapping,
            EncoderPhase.Released -> stay()
        }

        EncoderEvent.Resume -> when (state.phase) {
            EncoderPhase.Attached -> if (!state.paused) {
                stay()
            } else if (state.persistent) {
                EncoderTransition(
                    state.copy(paused = false),
                    listOf(EncoderAction.ResendConfig, EncoderAction.RequestKey,
                        EncoderAction.Nudge),
                )
            } else {
                EncoderTransition(
                    state.copy(phase = EncoderPhase.Swapping, paused = false),
                    listOf(EncoderAction.Rebuild),
                )
            }
            EncoderPhase.Empty -> if (!state.paused || state.display == DisplayPhase.None) {
                stay()
            } else {
                EncoderTransition(
                    state.copy(phase = EncoderPhase.Swapping, paused = false),
                    listOf(EncoderAction.Rebuild),
                )
            }
            EncoderPhase.Opening, EncoderPhase.Prepared, EncoderPhase.Swapping,
            EncoderPhase.Released -> stay()
        }

        is EncoderEvent.Suspend -> when (state.phase) {
            EncoderPhase.Attached -> when {
                state.suspended == event.suspended -> stay()
                // A detached encoder has no input surface to stop.
                state.paused && !state.persistent -> stay()
                else -> EncoderTransition(state, listOf(EncoderAction.ApplySuspend(event.suspended)))
            }
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Prepared,
            EncoderPhase.Swapping, EncoderPhase.Released -> stay()
        }

        is EncoderEvent.SuspendApplied -> when (state.phase) {
            EncoderPhase.Attached -> if (!event.applied) {
                stay()
            } else {
                EncoderTransition(state.copy(suspended = event.suspended), emptyList())
            }
            EncoderPhase.Empty, EncoderPhase.Opening, EncoderPhase.Prepared,
            EncoderPhase.Swapping, EncoderPhase.Released -> stay()
        }

        EncoderEvent.ReleasePrevious -> if (!state.previous) {
            stay()
        } else {
            EncoderTransition(
                state.copy(previous = false),
                listOf(EncoderAction.ReleasePreviousCodec),
            )
        }

        EncoderEvent.Release -> if (state.released) {
            stay()
        } else {
            EncoderTransition(
                EncoderState(phase = EncoderPhase.Released),
                listOf(EncoderAction.Detach, EncoderAction.ReleasePrepared,
                    EncoderAction.ReleaseDisplay, EncoderAction.ReleaseSurface),
            )
        }
    }
}

/** The closed token for a state in the field log. */
internal fun encoderToken(state: EncoderState): String = when (state.phase) {
    EncoderPhase.Empty -> "empty"
    EncoderPhase.Opening -> "opening"
    EncoderPhase.Prepared -> "prepared"
    EncoderPhase.Attached -> when {
        state.paused && state.suspended -> "paused+suspended"
        state.paused -> "paused"
        state.suspended -> "suspended"
        else -> "draining"
    }
    EncoderPhase.Swapping -> "swapping"
    EncoderPhase.Released -> "released"
}

/**
 * The holder the stream talks to: one state, one transition, one log line per
 * phase change (`stream N encoder: draining --pause--> paused`) and one per
 * display change (`stream N display: none --created--> virtual`).
 */
internal class EncoderLifecycle(
    private val stream: Int,
    private val log: (String) -> Unit,
) {
    @Volatile
    var state = EncoderState()
        private set

    fun dispatch(event: EncoderEvent): List<EncoderAction> {
        val before = state
        val step = encoderTransition(before, event)
        state = step.state
        if (encoderToken(step.state) != encoderToken(before)) {
            log("stream $stream encoder: ${encoderToken(before)} --${event.wire}--> ${encoderToken(step.state)}")
        }
        if (step.state.display != before.display) {
            log("stream $stream display: ${before.display.wire} --${event.wire}--> ${step.state.display.wire}")
        }
        return step.actions
    }
}
