package dev.pocketdeck.server

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.util.Base64
import java.io.ByteArrayOutputStream

/**
 * Lists launchable apps, renders icons and starts activities on a display.
 *
 * Launching goes through `IActivityManager.startActivity` with
 * `ActivityOptions.setLaunchDisplayId` (scrcpy's approach) and falls back to
 * `am start --display N`, which works because this process is shell. The
 * binder call returns an int: a negative value (e.g. `START_PERMISSION_DENIED`,
 * `START_CLASS_NOT_FOUND`) means the activity was not started, so the next
 * overload / the `am` fallback is tried.
 */
internal class AndroidLauncher(private val ctx: Context, private val log: (String) -> Unit) : Launcher, AppCatalog {

    private val activityManager: Any? = Hidden.proxy("android.app.IActivityManager", "activity")
    private val activityManagerClass = Hidden.iface("android.app.IActivityManager")
    private val iconCache = HashMap<String, String>()

    private var loggedBinderPath = false
    private var loggedAmPath = false

    private val pm get() = ctx.packageManager

    override fun launch(displayId: Int, pkg: String, activity: String?): Boolean {
        if (displayId < 0) return false
        val component = resolveComponent(pkg, activity) ?: run {
            log("no launcher activity for $pkg")
            return false
        }
        val intent = Intent(Intent.ACTION_MAIN).apply {
            setComponent(component)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (startViaBinder(intent, displayId)) return true
        return startViaAm(displayId, component)
    }

    override fun list(): List<AppEntry> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = runCatching { pm.queryIntentActivities(intent, 0) }.getOrDefault(emptyList())
        val out = ArrayList<AppEntry>(resolved.size)
        for (ri in resolved) {
            val ai = ri.activityInfo ?: continue
            // Our own launcher is reached from the phone-mode window, not the app list.
            if (ai.packageName == Session.OWN_PACKAGE) continue
            val label = runCatching { ri.loadLabel(pm).toString() }.getOrDefault(ai.packageName)
            out.add(AppEntry(ai.packageName, label, "${ai.packageName}/${ai.name}"))
        }
        return out.sortedBy { it.label.lowercase() }
    }

    override fun iconPng(pkg: String): String? {
        synchronized(iconCache) { iconCache[pkg]?.let { return it } }
        return try {
            val drawable = pm.getApplicationIcon(pkg)
            val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            val png = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            synchronized(iconCache) { iconCache[pkg] = png }
            png
        } catch (e: Throwable) {
            log("icon $pkg failed: ${e.message}")
            null
        }
    }

    // ------------------------------------------------------------------

    private fun resolveComponent(pkg: String, activity: String?): ComponentName? {
        if (activity != null && activity.isNotEmpty()) {
            return if (activity.startsWith("$pkg/")) {
                ComponentName.unflattenFromString(activity)
            } else {
                ComponentName(pkg, activity)
            }
        }
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(pkg)
        val ai = runCatching { pm.queryIntentActivities(intent, 0) }.getOrDefault(emptyList())
            .firstOrNull()?.activityInfo
            ?: return null
        return ComponentName(ai.packageName, ai.name)
    }

    private fun startViaBinder(intent: Intent, displayId: Int): Boolean {
        val am = activityManager ?: return false
        val cls = activityManagerClass ?: return false
        val options = ActivityOptions.makeBasic()
        options.setLaunchDisplayId(displayId)
        val bundle = options.toBundle()
        val candidates = cls.methods.filter { it.name == "startActivity" }
        if (candidates.isEmpty()) return false
        val order = LauncherOverloads.rank(candidates.map { m -> m.parameterTypes.map { it.name } })
        for (index in order) {
            val m = candidates[index]
            val args = Array<Any?>(m.parameterTypes.size) { i -> argFor(m.parameterTypes[i], i, intent, bundle) }
            val result = try {
                m.invoke(am, *args) as? Int ?: 0
            } catch (e: Throwable) {
                log("startActivity overload failed: ${e.message}")
                continue
            }
            if (result < 0) {
                log("startActivity returned $result")
                continue
            }
            if (!loggedBinderPath) {
                loggedBinderPath = true
                log("launching via IActivityManager.startActivity (${m.parameterTypes.size} args)")
            }
            return true
        }
        return false
    }

    private fun argFor(type: Class<*>, index: Int, intent: Intent, bundle: Bundle): Any? = when {
        type == Intent::class.java -> intent
        type == Bundle::class.java -> bundle
        // `callingPackage` is the only String we must fill; the others (resultWho,
        // resolvedType) legitimately accept null.
        type == String::class.java -> if (index == 1) "com.android.shell" else null
        type == Int::class.javaPrimitiveType -> 0
        type == Long::class.javaPrimitiveType -> 0L
        type == Boolean::class.javaPrimitiveType -> false
        type == Float::class.javaPrimitiveType -> 0f
        else -> null
    }

    private fun startViaAm(displayId: Int, component: ComponentName): Boolean {
        val cmd = "am start --display $displayId -n ${component.flattenToShortString()}"
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
            val out = p.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8)
            val err = p.errorStream.use { it.readBytes() }.toString(Charsets.UTF_8)
            val code = p.waitFor()
            val ok = code == 0 && !out.contains("Error") && !err.contains("Error")
            if (ok && !loggedAmPath) {
                loggedAmPath = true
                log("launching via am start --display")
            }
            if (!ok) log("am start on $displayId failed: $out$err")
            ok
        } catch (e: Throwable) {
            log("am start failed: ${e.message}")
            false
        }
    }

    private companion object {
        const val ICON_SIZE = 96
    }
}
