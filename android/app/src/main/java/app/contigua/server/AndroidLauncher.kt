package app.contigua.server

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Base64
import java.io.ByteArrayOutputStream

/**
 * Lists launchable apps, renders icons and starts activities on a display.
 *
 * Launching goes through `IActivityManager.startActivity` with
 * `ActivityOptions.setLaunchDisplayId` (the approach open-source mirroring tools use) and falls back to
 * `am start --display N`, which works because this process is shell. The
 * binder call returns an int: a negative value (e.g. `START_PERMISSION_DENIED`,
 * `START_CLASS_NOT_FOUND`) means the activity was not started, so the next
 * overload / the `am` fallback is tried.
 */
internal class AndroidLauncher(private val ctx: Context, private val log: (String) -> Unit) : Launcher, AppCatalog {

    private val activityManager: Any? = Hidden.proxy("android.app.IActivityManager", "activity")
    private val activityManagerClass = Hidden.iface("android.app.IActivityManager")
    private val iconCache = HashMap<String, String>()
    private val layersCache = HashMap<String, IconLayers?>()

    private var loggedBinderPath = false
    private var loggedAmPath = false

    private val pm get() = ctx.packageManager

    override fun launch(displayId: Int, pkg: String, activity: String?, newInstance: Boolean): Boolean {
        if (displayId < 0) return false
        val component = resolveComponent(pkg, activity) ?: run {
            log("no launcher activity for $pkg")
            return false
        }
        val flags = LaunchFlags.of(newInstance)
        val intent = Intent(Intent.ACTION_MAIN).apply {
            setComponent(component)
            addFlags(flags)
        }
        if (startViaBinder(intent, displayId)) return true
        return startViaAm(displayId, component, flags)
    }

    override fun view(displayId: Int, url: String): Boolean {
        if (displayId < 0) return false
        // Never let the system resolve this: if Contigua is the default
        // browser ("Open on Mac") the link would bounce back to the Mac.
        val probe = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE)
        // MATCH_ALL: without it a default browser hides every other handler (even when it is us).
        val handlers = runCatching { pm.queryIntentActivities(probe, PackageManager.MATCH_DEFAULT_ONLY or PackageManager.MATCH_ALL) }
            .getOrDefault(emptyList()).mapNotNull { it.activityInfo }
        val preferred = runCatching { pm.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY) }
            .getOrNull()?.activityInfo?.packageName
        val pkg = LoopGuard.pick(preferred, handlers.map { it.packageName })
        if (pkg == null) {
            log("view: no handler other than us")
            return false
        }
        val target = handlers.first { it.packageName == pkg }
        val component = ComponentName(target.packageName, target.name)
        val intent = Intent(probe).apply {
            setComponent(component)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (startViaBinder(intent, displayId)) return true
        // An argv array, not `sh -c`: the URL must never be parsed by a shell.
        return runAm(arrayOf("am", "start", "--display", displayId.toString(),
            "-a", Intent.ACTION_VIEW, "-c", Intent.CATEGORY_BROWSABLE, "-d", url,
            "-n", component.flattenToShortString()), displayId)
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
            val facts = LaunchFacts(
                launchMode = ai.launchMode,
                documentLaunchMode = ai.documentLaunchMode,
                multiInstanceProperty = supportsMultiInstance(ai),
            )
            out.add(
                AppEntry(
                    pkg = ai.packageName,
                    label = label,
                    activity = "${ai.packageName}/${ai.name}",
                    multi = MultiInstancePolicy.multi(ai.packageName, facts),
                ),
            )
        }
        val sorted = out.sortedBy { it.label.lowercase() }
        // The one line the emulator check reads for WIN-24: packages only, never
        // an app label.
        log("apps: ${sorted.size}, multi: ${sorted.filter { it.multi }.map { it.pkg }}")
        return sorted
    }

    /**
     * `PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI` for the launcher activity:
     * API 35+, and false on a phone that cannot answer (the property is the
     * app's own claim, not the platform's decision).
     */
    private fun supportsMultiInstance(ai: android.content.pm.ActivityInfo): Boolean {
        if (Build.VERSION.SDK_INT < 35) return false
        return runCatching {
            pm.getProperty(
                android.view.WindowManager.PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI,
                ComponentName(ai.packageName, ai.name),
            ).boolean
        }.getOrDefault(false)
    }

    override fun iconPng(pkg: String, px: Int?): String? {
        val flatSize = IconSizes.flat(px)
        val key = "$pkg@$flatSize"
        synchronized(iconCache) { iconCache[key]?.let { return it } }
        return try {
            val drawable = pm.getApplicationIcon(pkg)
            val bitmap = Bitmap.createBitmap(flatSize, flatSize, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, flatSize, flatSize)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            val png = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            synchronized(iconCache) { iconCache[key] = png }
            png
        } catch (e: Throwable) {
            log("icon $pkg failed: ${e.message}")
            null
        }
    }

    /** Layers of an adaptive icon, cached like the flat one; null is cached too. */
    override fun iconLayers(pkg: String, px: Int?): IconLayers? {
        val size = IconSizes.layer(px)
        val key = "$pkg@$size"
        synchronized(layersCache) { layersCache[key]?.let { return it } }
        val layers = try {
            val drawable = pm.getApplicationIcon(pkg) as? AdaptiveIconDrawable
                ?: return null
            val fg = renderLayer(drawable.foreground, size) ?: return null
            val bg = renderLayer(drawable.background, size) ?: return null
            IconLayers(
                fg = fg,
                bg = bg,
                mono = if (Build.VERSION.SDK_INT >= 33) renderLayer(drawable.monochrome, size) else null,
            )
        } catch (e: Throwable) {
            log("layers $pkg failed: ${e.message}")
            null
        }
        synchronized(layersCache) { layersCache[key] = layers }
        return layers
    }

    /** The whole 108 dp layer at `size` px. */
    private fun renderLayer(layer: Drawable?, size: Int): String? {
        layer ?: return null
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        layer.setBounds(0, 0, size, size)
        layer.draw(canvas)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
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

    /** The fallback launch: the same flags, through `am start` (`-f`). */
    private fun startViaAm(displayId: Int, component: ComponentName, flags: Int): Boolean =
        runAm(
            arrayOf(
                "am", "start", "--display", displayId.toString(),
                "-f", "0x%08x".format(flags),
                "-n", component.flattenToShortString(),
            ),
            displayId,
        )

    private fun runAm(argv: Array<String>, displayId: Int): Boolean {
        return try {
            val p = Runtime.getRuntime().exec(argv)
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
}

/**
 * The pixel sizes an icon is rendered at (`apps.icon`'s optional `px`, the side
 * of the 108 dp layer). A phone that predates `px` answers 216 px layers and a
 * 96 px flat icon, exactly as before.
 */
internal object IconSizes {
    const val DEFAULT_LAYER = 216
    const val MIN_LAYER = 216
    const val MAX_LAYER = 1296
    const val FLAT = 96

    /** The layer side for a requested `px`, clamped to what the launcher can draw. */
    fun layer(px: Int?): Int = (px ?: DEFAULT_LAYER).coerceIn(MIN_LAYER, MAX_LAYER)

    /** The flat icon stays 96 px unless `px` is given: then it covers the visible 2/3. */
    fun flat(px: Int?): Int = if (px == null) FLAT else layer(px) * 2 / 3
}
