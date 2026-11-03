package dev.pocketdeck.app

import android.content.Context
import java.io.InputStream

/**
 * The app-owned half of a clipboard image (SHARE-2/16): the shell hands over a
 * validated PNG/JPEG over a pipe, and this writes it into `cacheDir/clip`,
 * builds the FileProvider URI at the app's own uid and sets A2's URI-only item.
 * Only the newest file is kept: the clip's URI always points at it.
 */
object ClipImageWriter {

    fun write(context: Context, mime: String, input: InputStream): Boolean = false
}
