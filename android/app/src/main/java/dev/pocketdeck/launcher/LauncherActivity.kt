package dev.pocketdeck.launcher

import android.app.Activity
import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.EditText
import android.widget.GridView
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import dev.pocketdeck.R

/**
 * Phone-mode home screen. Runs on the virtual display the shell service created
 * and launches tapped apps onto the same display. Deliberately exported but with
 * no HOME category so it is never the device's launcher.
 */
class LauncherActivity : Activity() {

    private data class Entry(val label: String, val component: ComponentName, val icon: Drawable)

    private lateinit var grid: GridView
    private lateinit var search: EditText
    private var all: List<Entry> = emptyList()
    private var shown: List<Entry> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_launcher)
        grid = findViewById(R.id.appGrid)
        search = findViewById(R.id.search)
        grid.adapter = AppAdapter()
        grid.setOnItemClickListener { _, _, position, _ -> launch(shown[position]) }
        search.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) = filter(s?.toString().orEmpty())
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
        })
        loadApps()
    }

    private fun loadApps() {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val resolved = runCatching { pm.queryIntentActivities(intent, 0) }.getOrDefault(emptyList())
        all = resolved.mapNotNull { ri ->
            val ai = ri.activityInfo ?: return@mapNotNull null
            val label = runCatching { ri.loadLabel(pm).toString() }.getOrDefault(ai.packageName)
            val icon = runCatching { ri.loadIcon(pm) }.getOrNull() ?: return@mapNotNull null
            Entry(label, ComponentName(ai.packageName, ai.name), icon)
        }.sortedBy { it.label.lowercase() }
        filter(search.text.toString())
    }

    private fun filter(query: String) {
        val q = query.trim().lowercase()
        shown = if (q.isEmpty()) all else all.filter { it.label.lowercase().contains(q) }
        (grid.adapter as BaseAdapter).notifyDataSetChanged()
        if (shown.isEmpty() && q.isNotEmpty()) {
            Toast.makeText(this, getString(R.string.launcher_no_match), Toast.LENGTH_SHORT).show()
        }
    }

    private fun launch(entry: Entry) {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            component = entry.component
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val displayId = display?.displayId ?: android.view.Display.DEFAULT_DISPLAY
        val options = ActivityOptions.makeBasic().apply { setLaunchDisplayId(displayId) }
        try {
            startActivity(intent, options.toBundle())
        } catch (e: Throwable) {
            Toast.makeText(this, e.message ?: "launch failed", Toast.LENGTH_SHORT).show()
        }
    }

    private inner class AppAdapter : BaseAdapter() {
        override fun getCount(): Int = shown.size
        override fun getItem(position: Int): Any = shown[position]
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val view = convertView ?: layoutInflater.inflate(R.layout.row_app, parent, false)
            val entry = shown[position]
            view.findViewById<ImageView>(R.id.appIcon).setImageDrawable(entry.icon)
            view.findViewById<TextView>(R.id.appLabel).text = entry.label
            return view
        }
    }
}
