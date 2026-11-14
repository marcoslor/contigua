package app.contigua.debug

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.Looper
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

/**
 * Debug-only: prints the accessibility tree of every display, so a check can
 * read an app window's virtual display, which `uiautomator dump` never shows.
 *
 *   CLASSPATH=/data/local/tmp/contigua-debug.apk app_process /system/bin \
 *       app.contigua.debug.A11yDump [--display <id>]
 *
 * Runs as the shell user, as `uiautomator` does, and holds the UiAutomation
 * connection only while it dumps. Other accessibility services stay on.
 *
 * One line per window, then one per node, indented by depth:
 *   d=47 window "Spotify" type=APPLICATION focused
 *     Button "Podcasts" #com.spotify.music:id/chip {475,30,620,110} click
 *
 * The output holds whatever text is on screen. Read it in a terminal; never
 * commit it or attach it to an issue.
 */
object A11yDump {

    private const val CONNECT_FLAGS = 1 // UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES

    @JvmStatic
    fun main(args: Array<String>) {
        val only = parseDisplay(args)
        Looper.prepareMainLooper()
        // The system context needs the looper's own thread; UiAutomation then
        // answers its connect on that looper, so the dump runs on its own
        // thread while the main thread loops.
        val context = systemContext()
        Thread({
            val code = try {
                dump(context, only)
                0
            } catch (t: Throwable) {
                val cause = generateSequence(t) { it.cause }.last()
                System.err.println("a11ydump: ${cause.javaClass.simpleName}: ${cause.message}")
                cause.stackTrace.take(6).forEach { System.err.println("  at $it") }
                1
            }
            System.out.flush()
            System.exit(code)
        }, "a11ydump").start()
        Looper.loop()
    }

    private fun parseDisplay(args: Array<String>): Int? {
        if (args.isEmpty()) return null
        if (args.size == 2 && args[0] == "--display") args[1].toIntOrNull()?.let { return it }
        System.err.println("usage: A11yDump [--display <id>]")
        System.exit(2)
        return null
    }

    private fun systemContext(): Context {
        val threadClass = Class.forName("android.app.ActivityThread")
        val thread = threadClass.getMethod("systemMain").invoke(null)
        return threadClass.getMethod("getSystemContext").invoke(thread) as Context
    }

    private fun connect(context: Context): UiAutomation {
        val iface = Class.forName("android.app.IUiAutomationConnection")
        val connection = Class.forName("android.app.UiAutomationConnection")
            .getDeclaredConstructor().newInstance()
        val automation = runCatching {
            UiAutomation::class.java.getDeclaredConstructor(Context::class.java, iface)
                .newInstance(context, connection)
        }.getOrElse {
            UiAutomation::class.java.getDeclaredConstructor(Looper::class.java, iface)
                .newInstance(Looper.getMainLooper(), connection)
        }
        UiAutomation::class.java.getDeclaredMethod("connect", Int::class.javaPrimitiveType)
            .invoke(automation, CONNECT_FLAGS)
        val info = automation.serviceInfo
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        automation.serviceInfo = info
        return automation
    }

    private fun dump(context: Context, only: Int?) {
        val automation = connect(context)
        try {
            // The window list fills in after the flags land.
            Thread.sleep(300)
            val all = automation.windowsOnAllDisplays
            for (i in 0 until all.size()) {
                val display = all.keyAt(i)
                if (only != null && display != only) continue
                for (window in all.valueAt(i)) printWindow(display, window)
            }
        } finally {
            runCatching { UiAutomation::class.java.getDeclaredMethod("disconnect").invoke(automation) }
        }
    }

    private fun printWindow(display: Int, window: AccessibilityWindowInfo) {
        val line = StringBuilder("d=").append(display)
            .append(" window \"").append(window.title ?: "").append('"')
            .append(" type=").append(windowType(window.type))
        if (window.isFocused) line.append(" focused")
        if (window.isActive) line.append(" active")
        println(line)
        val root = window.root ?: return
        printNode(root, 1)
    }

    private fun printNode(node: AccessibilityNodeInfo, depth: Int) {
        val bounds = Rect().also { node.getBoundsInScreen(it) }
        val line = StringBuilder("  ".repeat(depth))
            .append(node.className?.toString()?.substringAfterLast('.') ?: "?")
        node.text?.let { line.append(" \"").append(it).append('"') }
        node.contentDescription?.let { line.append(" [").append(it).append(']') }
        node.viewIdResourceName?.let { line.append(" #").append(it) }
        line.append(" {").append(bounds.left).append(',').append(bounds.top)
            .append(',').append(bounds.right).append(',').append(bounds.bottom).append('}')
        if (node.isClickable) line.append(" click")
        if (node.isFocused) line.append(" focused")
        if (node.isSelected) line.append(" selected")
        if (node.isCheckable) line.append(if (node.isChecked) " checked" else " unchecked")
        if (!node.isEnabled) line.append(" disabled")
        println(line)
        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { printNode(it, depth + 1) }
        }
    }

    private fun windowType(type: Int): String = when (type) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "APPLICATION"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "INPUT_METHOD"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "SYSTEM"
        AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "ACCESSIBILITY_OVERLAY"
        AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "SPLIT_SCREEN_DIVIDER"
        AccessibilityWindowInfo.TYPE_MAGNIFICATION_OVERLAY -> "MAGNIFICATION_OVERLAY"
        else -> type.toString()
    }
}
