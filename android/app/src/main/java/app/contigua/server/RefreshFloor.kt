package app.contigua.server

import android.os.Binder
import android.os.IBinder

/**
 * The panel's refresh floor while app windows stream (docs/specs/app-windows.md
 * WIN-76).
 *
 * SurfaceFlinger paces every display by the built-in panel, so a window
 * display draws no faster than the panel's render rate, even in a display
 * group of its own. In Always-On Display One UI's AOD plugin caps the panel at
 * 30 Hz with a `RefreshRateMaxLimitToken` (`PRIORITY_REFRESH_RATE_MAX_LIMIT`,
 * priority 1), and every window dropped to 15–35 fps. A
 * `RefreshRateMinLimitToken` votes at `PRIORITY_REFRESH_RATE_MIN_LIMIT`
 * (priority 2), which outranks it, so holding one at [HZ] keeps the windows'
 * pace while the phone's own screen dozes, without waking it or changing a
 * setting (#142).
 *
 * [acquire] is the platform call: the token's release, or null where the
 * phone has no such token or refuses it. The holder only makes sure there is
 * at most one token and that it is released once.
 */
internal class RefreshFloor(private val acquire: (hz: Int) -> (() -> Unit)?) {

    private var release: (() -> Unit)? = null

    val held: Boolean @Synchronized get() = release != null

    /** Takes the floor unless it is held; answers the log token. */
    @Synchronized
    fun hold(): String {
        if (release == null) release = runCatching { acquire(HZ) }.getOrNull()
        return if (release != null) "floor=$HZ" else "floor=none"
    }

    /** Releases the floor (harmless when none is held). */
    @Synchronized
    fun drop() {
        val r = release ?: return
        release = null
        runCatching { r() }
    }

    companion object {
        /** The window display's own rate (WIN-61's default). */
        const val HZ = 60
    }
}

/**
 * One UI's refresh-rate token, through the hidden
 * `IDisplayManager.acquireRefreshRateMinLimitToken(IBinder, int, String)`.
 * The platform links the token to [Binder] we pass, so it goes when this
 * process dies; it answers null for a caller it does not allow.
 */
internal object AndroidRefreshFloor {
    private const val IFACE = "android.hardware.display.IDisplayManager"

    /** The tag `dumpsys display` shows: `RefreshRateMinLimitToken:contigua`. */
    const val TAG = "contigua"

    fun acquire(hz: Int): (() -> Unit)? {
        val dm = Hidden.proxy(IFACE, "display") ?: return null
        val method = Hidden.method(
            dm.javaClass, "acquireRefreshRateMinLimitToken",
            IBinder::class.java, Hidden.T_INT, String::class.java,
        ) ?: return null
        val owner = Binder()
        val token = method.invoke(dm, owner, hz, TAG) ?: return null
        val release = token.javaClass.getMethod("release")
        return {
            release.invoke(token)
            // The platform watches this binder; keep it until the release.
            java.lang.ref.Reference.reachabilityFence(owner)
        }
    }
}
