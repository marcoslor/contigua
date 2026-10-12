package dev.pocketdeck.launcher

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.view.Display
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.graphics.drawable.toBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.material3.SnackbarHostState
import dev.pocketdeck.R
import dev.pocketdeck.ui.theme.PocketDeckTheme
import kotlinx.coroutines.launch

/**
 * Phone-mode home screen. Runs on the virtual display the shell service created
 * and launches tapped apps onto the same display. Deliberately exported but with
 * no HOME category so it is never the device's launcher.
 */
class LauncherActivity : ComponentActivity() {

    private var apps: List<LauncherApp> = emptyList()
    private var components: Map<String, ComponentName> = emptyMap()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val loaded = loadApps()
        apps = loaded.map { it.first }
        components = loaded.associate { it.first.key to it.second }

        setContent {
            PocketDeckTheme {
                var query by rememberSaveable { mutableStateOf("") }
                val scope = rememberCoroutineScope()
                val snackbarHostState = remember { SnackbarHostState() }
                LauncherScreen(
                    apps = apps,
                    query = query,
                    onQueryChange = { query = it },
                    onLaunch = { app ->
                        val component = components[app.key]
                        if (component == null || !launch(component)) {
                            scope.launch {
                                snackbarHostState.showSnackbar(getString(R.string.launcher_launch_failed))
                            }
                        }
                    },
                    snackbarHostState = snackbarHostState,
                )
            }
        }
    }

    private fun loadApps(): List<Pair<LauncherApp, ComponentName>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = runCatching { pm.queryIntentActivities(intent, 0) }.getOrDefault(emptyList())
        return resolved.mapNotNull { ri ->
            val ai = ri.activityInfo ?: return@mapNotNull null
            val label = runCatching { ri.loadLabel(pm).toString() }.getOrDefault(ai.packageName)
            val drawable = runCatching { ri.loadIcon(pm) }.getOrNull() ?: return@mapNotNull null
            val icon = runCatching {
                drawable.toBitmap(ICON_SIZE_PX, ICON_SIZE_PX).asImageBitmap()
            }.getOrNull() ?: return@mapNotNull null
            LauncherApp(
                key = "${ai.packageName}/${ai.name}",
                label = label,
                icon = icon,
            ) to ComponentName(ai.packageName, ai.name)
        }.sortedBy { it.first.label.lowercase() }
    }

    private fun launch(component: ComponentName): Boolean {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            this.component = component
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val displayId = display?.displayId ?: Display.DEFAULT_DISPLAY
        val options = ActivityOptions.makeBasic().apply { setLaunchDisplayId(displayId) }
        return runCatching {
            startActivity(intent, options.toBundle())
            true
        }.getOrDefault(false)
    }

    private companion object {
        const val ICON_SIZE_PX = 144
    }
}
