package app.contigua.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.view.KeyEvent
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.FileProvider
import androidx.core.view.ContentInfoCompat
import androidx.core.view.OnReceiveContentListener
import androidx.core.view.ViewCompat
import java.io.File

/**
 * Debug builds only (docs/design/dragdrop.md): the two fields A2 is tested
 * with. A plain `EditText` must paste nothing from an image clip; a field whose
 * OnReceiveContentListener accepts image types must receive the image's URI.
 *
 *   am start -n app.contigua/.app.PasteDebugActivity --es field plain
 *   adb shell input keyevent 279
 *
 * `--es action copy --es text <string>` writes a plain-text primary clip as the
 * focused app; `--es action exists` reads the primary clip's description (never
 * its content) and logs whether one exists. The read waits for window focus:
 * the app-facing clipboard API returns null to an unfocused app, so an onCreate
 * read would report a clip that is there as absent. Both log lengths and flags
 * only.
 *
 * `--es item empty|uri` first puts the debug image on the clipboard in that
 * item shape (the comparison the review asks for); without it the clipboard is
 * whatever the real ShellClipboard wrote from a clip.image.* transfer. The
 * result is one logcat line (`PasteDebug: plain text length=…`, `rich image
 * bytes=…`); no text or path is ever logged.
 *
 * `--es field noset` focuses a third field that offers no `ACTION_SET_TEXT`,
 * as a view that draws its own text does, so the person's typing takes the
 * clipboard fallback there (WIN-80, tools/emulator/clip-keep.sh); it logs
 * `noset text length=…`. `--es expect 61.e9` (hex code points) adds
 * ` match=true|false` to each length line: whether the field now holds
 * exactly that text, so an order can be checked without logging the text.
 */
class PasteDebugActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val plain = EditText(this).apply {
            hint = "plain field"
            inputType = android.text.InputType.TYPE_CLASS_TEXT
        }
        val rich = EditText(this).apply {
            hint = "image field"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or
                android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE
        }
        val noset = NoSetTextField(this).apply {
            hint = "no set text"
            inputType = android.text.InputType.TYPE_CLASS_TEXT
        }
        val result = TextView(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(plain, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(rich, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(noset, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(result, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        setContentView(layout)

        plain.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                Log.i(TAG, "plain text length=${s?.length ?: 0}${match(s)}")  // log-ok: a length and a boolean, never the text
            }
        })
        noset.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                Log.i(TAG, "noset text length=${s?.length ?: 0}${match(s)}")  // log-ok: a length and a boolean, never the text
            }
        })
        ViewCompat.setOnReceiveContentListener(rich, arrayOf("image/*"),
            OnReceiveContentListener { _, payload -> received(payload, result) })

        when (intent.getStringExtra("item")) {
            "empty" -> setClip(ClipData.Item("", null, imageUri()), "image/png", plain)
            "uri" -> setClip(ClipData.Item(imageUri()), "image/png", plain)
            else -> Unit
        }

        val clipboard = getSystemService(ClipboardManager::class.java)
        when (intent.getStringExtra("action")) {
            "copy" -> {
                val text = intent.getStringExtra("text") ?: ""
                clipboard.setPrimaryClip(ClipData.newPlainText("Paste debug", text))
                Log.i(TAG, "copy length=${text.length}")  // log-ok: a length only, never the text
            }
            "exists" ->
                // Focus (not this onCreate) decides when the app may read: the
                // clipboard API answers null to an unfocused app.
                window.decorView.post { reportExistsIfFocused() }
            else -> Unit
        }

        val field = intent.getStringExtra("field")
        val name = if (field == "rich" || field == "noset") field else "plain"
        val target = when (name) {
            "rich" -> rich
            "noset" -> noset
            else -> plain
        }
        target.requestFocus()
        Log.i(TAG, "ready field=$name " +  // log-ok: fixed state names, never text
            "item=${intent.getStringExtra("item") ?: "keep"}")
    }

    /** `--es expect`'s text, from dot-separated hex code points; null without it. */
    private val expected: String? by lazy {
        intent.getStringExtra("expect")?.let { cps ->
            runCatching {
                cps.split('.').filter { it.isNotEmpty() }.joinToString("") { String(Character.toChars(it.toInt(16))) }
            }.getOrNull()
        }
    }

    private fun match(s: Editable?): String = expected?.let { " match=${s?.toString() == it}" } ?: ""

    /** The exists probe runs once, only after this activity's window has focus. */
    private var existsReported = false

    private fun reportExistsIfFocused() {
        if (existsReported || !hasWindowFocus()) return
        existsReported = true
        // The description has no owner check and carries no content.
        val description = getSystemService(ClipboardManager::class.java).primaryClipDescription
        Log.i(TAG, "clip exists=${description != null} mimes=${description?.mimeTypeCount ?: 0}")  // log-ok: a state and a count, never the clip
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) reportExistsIfFocused()
    }

    /** Numbers only: proves whether the injected key reaches the field at all. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        Log.i(TAG, "key code=${event.keyCode} action=${event.action} meta=${event.metaState}")  // log-ok: numbers only
        return super.dispatchKeyEvent(event)
    }

    /** The rich field's answer: the image's real byte length, never its content. */
    private fun received(payload: ContentInfoCompat, result: TextView): ContentInfoCompat? {
        val uri = payload.clip.getItemAt(0).uri
        val bytes = uri?.let { content ->
            runCatching { contentResolver.openInputStream(content)?.use { it.readBytes().size } }
                .getOrNull()
        } ?: -1
        result.text = "image bytes=$bytes"
        Log.i(TAG, "rich image bytes=$bytes")
        return null
    }

    private fun setClip(item: ClipData.Item, mime: String, plain: EditText) {
        val clip = ClipData(ClipDescription("Paste debug", arrayOf(mime)), item)
        getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        plain.setText("")
        Log.i(TAG, "clip set text=${item.text?.toString()?.length ?: -1} " +  // log-ok: a length only, never the text
            "uri=${item.uri != null}")
    }

    /** A small PNG inside the provider's `cache/shared/` folder. */
    private fun imageUri() = FileProvider.getUriForFile(
        this, "app.contigua.fileprovider", imageFile())

    private fun imageFile(): File {
        val dir = File(cacheDir, "shared").apply { mkdirs() }
        val file = File(dir, "paste-debug.png")
        // Always rewrite: an earlier run could leave a zero-byte file (boot 3
        // read 0 bytes through the provider), and the image must be real.
        val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return file
    }

    private companion object {
        const val TAG = "PasteDebug"
    }
}

/** A field that offers no `ACTION_SET_TEXT` to accessibility, and still takes keys and pastes. */
private class NoSetTextField(context: Context) : EditText(context) {
    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT)
    }
}
