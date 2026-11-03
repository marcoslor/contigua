package dev.pocketdeck.app

import android.app.Activity
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.graphics.Bitmap
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.view.KeyEvent
import android.view.ViewGroup
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
 *   am start -n dev.pocketdeck/.app.PasteDebugActivity --es field plain
 *   adb shell input keyevent 279
 *
 * `--es item empty|uri` first puts the debug image on the clipboard in that
 * item shape (the comparison the review asks for); without it the clipboard is
 * whatever the real ShellClipboard wrote from a clip.image.* transfer. The
 * result is one logcat line (`PasteDebug: plain text length=…`, `rich image
 * bytes=…`); no text or path is ever logged.
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
        val result = TextView(this)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(plain, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(rich, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(result, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        setContentView(layout)

        plain.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                Log.i(TAG, "plain text length=${s?.length ?: 0}")
            }
        })
        ViewCompat.setOnReceiveContentListener(rich, arrayOf("image/*"),
            OnReceiveContentListener { _, payload -> received(payload, result) })

        when (intent.getStringExtra("item")) {
            "empty" -> setClip(ClipData.Item("", null, imageUri()), "image/png", plain)
            "uri" -> setClip(ClipData.Item(imageUri()), "image/png", plain)
            else -> Unit
        }

        val field = intent.getStringExtra("field")
        val target = if (field == "rich") rich else plain
        target.requestFocus()
        Log.i(TAG, "ready field=${if (field == "rich") "rich" else "plain"} " +  // log-ok: fixed state names, never text
            "item=${intent.getStringExtra("item") ?: "keep"}")
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
        this, "dev.pocketdeck.fileprovider", imageFile())

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
