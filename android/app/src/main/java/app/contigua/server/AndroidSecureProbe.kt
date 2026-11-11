package app.contigua.server

import android.app.KeyguardManager
import android.content.Context
import java.util.concurrent.TimeUnit

/**
 * Reads display 0's secure-surface state at shell UID
 * (docs/PROTOCOL.md "Secure screens").
 *
 * Two sources, because one alone lies:
 * - the focused window's `FLAG_SECURE` catches secure apps, and on a release
 *   build also the keyguard bouncer (SystemUI sets the flag there);
 * - a debuggable build deliberately skips that flag for the bouncer, so ask
 *   SystemUI's keyguard view manager whether the bouncer is showing.
 *
 * Both reads are `dumpsys` calls; [Session] polls this at most once a second
 * and only while a phone window stream is open.
 */
internal class AndroidSecureProbe(
    private val ctx: Context,
    private val log: (String) -> Unit,
) : SecureProbe {

    private var loggedUnreadable = false

    override fun read(): Boolean? {
        val dump = exec(WINDOW_DUMP) ?: return unreadable("window")
        val secure = SecureDump.focusedSecure(dump) ?: return unreadable("focused window flags")
        if (secure) return true
        // The bouncer only exists while the keyguard is up; skip the heavier
        // SystemUI dump on an unlocked phone.
        val keyguardShowing = runCatching {
            (ctx.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isDeviceLocked ?: false
        }.getOrDefault(false)
        if (!keyguardShowing) return false
        return SecureDump.bouncerShowing(exec(BOUNCER_DUMP) ?: return false)
    }

    private fun exec(command: String): String? = runCatching {
        val process = ProcessBuilder("/system/bin/sh", "-c", command)
            .redirectErrorStream(true)
            .start()
        val out = process.inputStream.bufferedReader().use { it.readText() }
        if (!process.waitFor(5, TimeUnit.SECONDS)) {
            process.destroy()
            return null
        }
        out.takeIf { process.exitValue() == 0 }
    }.getOrNull()

    private fun unreadable(why: String): Boolean? {
        if (!loggedUnreadable) {
            loggedUnreadable = true
            log("state: secure unreadable ($why)")
        }
        return null
    }

    private companion object {
        /**
         * `dumpsys window` is large on OEM builds; keep the display focus, the
         * window list, its attrs and the flag lines (API 36 prints them on the
         * next line). The flags may use the numeric or the named form.
         */
        const val WINDOW_DUMP =
            "/system/bin/dumpsys window | /system/bin/grep -E " +
                "'^ *Display: mDisplayId=|mCurrentFocus=|^ *Window #|mAttrs=|fl='"

        /** SystemUI's keyguard view manager is the only one that knows the bouncer. */
        const val BOUNCER_DUMP =
            "/system/bin/dumpsys activity service com.android.systemui/.SystemUIService | " +
                "/system/bin/grep 'isBouncerShowing'"
    }
}
