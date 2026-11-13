package app.contigua.server

/**
 * The one virtual device app windows' displays come from
 * (docs/specs/app-windows.md WIN-75): made with the first window display,
 * shared by every later one, and closed with the last.
 *
 * One UI keeps a plain virtual display in the panel's display group whatever
 * its flags, but gives a virtual device's displays a group of their own
 * (docs/research/lock-fade.md, option 1). So the device is what lets a window
 * keep streaming while the phone sleeps, without touching the phone's screen.
 *
 * The lifecycle is one pure machine keyed by the streams that hold a display
 * from the device; [WindowDevices] performs its two platform calls.
 */
internal sealed interface WindowDeviceState {
    /** No device: the next window makes one. */
    data object Closed : WindowDeviceState

    /** A live device and the streams whose displays came from it (never empty). */
    data class Open(val holders: Set<Int>) : WindowDeviceState
}

internal sealed interface WindowDeviceEvent {
    val wire: String

    /** A window display is wanted for [stream]. */
    data class Acquire(val stream: Int) : WindowDeviceEvent {
        override val wire: String get() = "acquire"
    }

    /** The device the last [Acquire] asked for was made ([ok]) or could not be. */
    data class Made(val stream: Int, val ok: Boolean) : WindowDeviceEvent {
        override val wire: String get() = if (ok) "made" else "makeFailed"
    }

    /** [stream]'s display was released. */
    data class Release(val stream: Int) : WindowDeviceEvent {
        override val wire: String get() = "release"
    }

    /** A display call on the device failed: the platform closed it (its association went). */
    data object Lost : WindowDeviceEvent {
        override val wire: String get() = "lost"
    }

    /** The service stops. */
    data object Stop : WindowDeviceEvent {
        override val wire: String get() = "stop"
    }
}

internal sealed interface WindowDeviceAction {
    /** Make the device now; answer with [WindowDeviceEvent.Made]. */
    data object Make : WindowDeviceAction

    /** [stream]'s display comes from the device. */
    data class UseDevice(val stream: Int) : WindowDeviceAction

    /** [stream] takes the plain route (WIN-74). */
    data class UsePlain(val stream: Int) : WindowDeviceAction

    /** Close the device (harmless when the platform already did). */
    data object Close : WindowDeviceAction
}

/** The pure rule: `(state, event) -> (state, actions)`, every pair answered. */
internal fun windowDeviceStep(
    state: WindowDeviceState,
    event: WindowDeviceEvent,
): Pair<WindowDeviceState, List<WindowDeviceAction>> = when (state) {
    WindowDeviceState.Closed -> when (event) {
        is WindowDeviceEvent.Acquire -> state to listOf(WindowDeviceAction.Make)
        is WindowDeviceEvent.Made -> if (event.ok) {
            WindowDeviceState.Open(setOf(event.stream)) to listOf(WindowDeviceAction.UseDevice(event.stream))
        } else {
            state to listOf(WindowDeviceAction.UsePlain(event.stream))
        }
        is WindowDeviceEvent.Release, WindowDeviceEvent.Lost, WindowDeviceEvent.Stop -> state to emptyList()
    }

    is WindowDeviceState.Open -> when (event) {
        is WindowDeviceEvent.Acquire ->
            WindowDeviceState.Open(state.holders + event.stream) to listOf(WindowDeviceAction.UseDevice(event.stream))
        // Only a closed device is made.
        is WindowDeviceEvent.Made -> state to emptyList()
        is WindowDeviceEvent.Release -> when {
            event.stream !in state.holders -> state to emptyList()
            state.holders.size == 1 -> WindowDeviceState.Closed to listOf(WindowDeviceAction.Close)
            else -> WindowDeviceState.Open(state.holders - event.stream) to emptyList()
        }
        WindowDeviceEvent.Lost, WindowDeviceEvent.Stop ->
            WindowDeviceState.Closed to listOf(WindowDeviceAction.Close)
    }
}

/** What making the device answered: the device, or a closed reason for the log. */
internal sealed interface DeviceMake<out D> {
    data class Made<D>(val device: D) : DeviceMake<D>

    /** `no_service`, `no_association` or `refused` (WIN-75). */
    data class Failed(val reason: String) : DeviceMake<Nothing>
}

/**
 * The live holder: keeps the state, performs [make] and [close], and logs
 * every change as `windowdevice: <from> --<event>--> <to> holders=<n>`.
 * [D] is the platform's device; the JVM tests pass a fake.
 */
internal class WindowDevices<D : Any>(
    private val make: () -> DeviceMake<D>,
    private val close: (D) -> Unit,
    private val log: (String) -> Unit,
) {
    private var state: WindowDeviceState = WindowDeviceState.Closed
    private var device: D? = null

    val current: WindowDeviceState @Synchronized get() = state

    /**
     * The device [stream]'s display should come from, made if needed, or null
     * for the plain route. A non-null answer makes [stream] a holder until its
     * [release].
     */
    @Synchronized
    fun acquire(stream: Int): D? {
        var answer: D? = null
        val pending = ArrayDeque<WindowDeviceEvent>()
        pending.add(WindowDeviceEvent.Acquire(stream))
        while (pending.isNotEmpty()) {
            for (action in dispatch(pending.removeFirst())) {
                when (action) {
                    WindowDeviceAction.Make -> {
                        val made = make()
                        when (made) {
                            is DeviceMake.Made -> device = made.device
                            is DeviceMake.Failed -> log("windowdevice: not made reason=${made.reason}")
                        }
                        pending.add(WindowDeviceEvent.Made(stream, made is DeviceMake.Made))
                    }
                    is WindowDeviceAction.UseDevice -> answer = device
                    is WindowDeviceAction.UsePlain -> answer = null
                    WindowDeviceAction.Close -> closeDevice()
                }
            }
        }
        return answer
    }

    @Synchronized
    fun release(stream: Int) = run(WindowDeviceEvent.Release(stream))

    /** A display call on the device failed: the next [acquire] makes a new one. */
    @Synchronized
    fun lost() = run(WindowDeviceEvent.Lost)

    @Synchronized
    fun stop() = run(WindowDeviceEvent.Stop)

    private fun run(event: WindowDeviceEvent) {
        for (action in dispatch(event)) {
            if (action == WindowDeviceAction.Close) closeDevice()
        }
    }

    private fun closeDevice() {
        val d = device ?: return
        device = null
        runCatching { close(d) }
    }

    private fun dispatch(event: WindowDeviceEvent): List<WindowDeviceAction> {
        val before = state
        val (next, actions) = windowDeviceStep(before, event)
        state = next
        if (next != before) {
            log("windowdevice: ${name(before)} --${event.wire}--> ${name(next)} holders=${holders(next)}")
        }
        return actions
    }

    private fun name(s: WindowDeviceState): String = when (s) {
        WindowDeviceState.Closed -> "Closed"
        is WindowDeviceState.Open -> "Open"
    }

    private fun holders(s: WindowDeviceState): Int = (s as? WindowDeviceState.Open)?.holders?.size ?: 0
}
