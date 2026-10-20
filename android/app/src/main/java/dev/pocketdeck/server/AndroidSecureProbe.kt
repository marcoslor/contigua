package dev.pocketdeck.server

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
        val focus = focusedWindow(dump) ?: return unreadable("no focused window block")
        if (focus.secure) return true
        // The bouncer is a SystemUI window; skip the heavier keyguard dump for
        // every other app.
        if (!focus.pkg.startsWith(SYSTEMUI)) return false
        val keyguardShowing = runCatching {
            (ctx.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isDeviceLocked ?: false
        }.getOrDefault(false)
        if (!keyguardShowing) return false
        return bouncerShowing()
    }

    private data class Focus(val token: String, val pkg: String, val secure: Boolean)

    /**
     * The focused window of display 0, from the per-display block first (a
     * secondary display's focus must not leak into the mirror) and the window
     * list for its flags.
     */
    private fun focusedWindow(dump: String): Focus? {
        var display = -1
        var token: String? = null
        var pkg = ""
        for (line in dump.lineSequence()) {
            val displayLine = DISPLAY.find(line)
            if (displayLine != null) {
                display = displayLine.groupValues[1].toIntOrNull() ?: -1
                continue
            }
            val m = FOCUS.find(line) ?: continue
            if (display == 0) {
                token = m.groupValues[1]
                pkg = m.groupValues[2]
            }
        }
        val focused = token ?: return null
        val flags = windowFlags(dump, focused) ?: return null
        return Focus(focused, pkg, flags and FLAG_SECURE != 0)
    }

    /** The `fl=` window flags of the window whose token is [token]. */
    private fun windowFlags(dump: String, token: String): Int? {
        var inWindow = false
        for (line in dump.lineSequence()) {
            if (WINDOW_HEADER.containsMatchIn(line)) {
                if (inWindow) return null // moved past our block without mAttrs
                inWindow = line.contains("Window{$token ")
                continue
            }
            if (!inWindow) continue
            ATTRS_FLAGS.find(line)?.let { return it.groupValues[1].toIntOrNull(16) }
        }
        return null
    }

    private fun bouncerShowing(): Boolean {
        val out = exec(BOUNCER_DUMP) ?: return false
        return BOUNCER_SHOWING.containsMatchIn(out)
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
        const val SYSTEMUI = "com.android.systemui"
        const val FLAG_SECURE = 0x00002000

        val DISPLAY = Regex("^\\s*Display: mDisplayId=(\\d+)")
        val FOCUS = Regex("^\\s*mCurrentFocus=Window\\{([0-9a-f]+) u\\d+ ([^ }/]+)")
        val WINDOW_HEADER = Regex("^\\s*Window #\\d+ Window\\{")
        val ATTRS_FLAGS = Regex("\\bfl=0x([0-9a-fA-F]+)")
        val BOUNCER_SHOWING = Regex("isBouncerShowing\\(\\):\\s*true")

        /**
         * `dumpsys window` is large on OEM builds; keep the display blocks, the
         * focus lines and the window list's flags, which is all the parse needs.
         */
        const val WINDOW_DUMP =
            "/system/bin/dumpsys window | /system/bin/grep -E " +
                "'^  Display: mDisplayId=|^    mCurrentFocus=|^  Window #|mAttrs='"

        /** SystemUI's keyguard view manager is the only one that knows the bouncer. */
        const val BOUNCER_DUMP =
            "/system/bin/dumpsys activity service com.android.systemui/.SystemUIService | " +
                "/system/bin/grep 'isBouncerShowing'"
    }
}
