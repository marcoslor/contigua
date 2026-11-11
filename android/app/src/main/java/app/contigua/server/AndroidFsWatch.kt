package app.contigua.server

import android.content.Context
import android.os.FileObserver
import android.provider.MediaStore
import java.io.File

/**
 * The phone's change source (docs/design/files.md §2): one `FileObserver`
 * (inotify) per folder, non-recursive, and MediaStore's generation for the
 * fallback when a watch cannot be placed.
 *
 * The observer's own thread calls back, so [FsWatcher] does the coalescing; the
 * mask is the one the design names — a create, a delete, a move either way and
 * a finished write.
 */
class AndroidFsWatchSource(
    /** The app's context (Shizuku hands it in): only the generation needs it. */
    private val app: Context?,
    private val log: (String) -> Unit = {},
) : FsWatchSource {

    override fun observe(dir: File, onEvent: (String?) -> Unit): FsWatchHandle {
        val observer = object : FileObserver(dir, MASK) {
            override fun onEvent(event: Int, name: String?) {
                onEvent(name)
            }
        }
        observer.startWatching()
        return FsWatchHandle { runCatching { observer.stopWatching() } }
    }

    override fun generation(): Long? {
        val app = app ?: return null
        return runCatching {
            MediaStore.getGeneration(app, MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }.onFailure { log("fs: generation failed: ${it.javaClass.simpleName}") }.getOrNull()
    }

    companion object {
        private const val MASK = FileObserver.CREATE or FileObserver.DELETE or
            FileObserver.MOVED_FROM or FileObserver.MOVED_TO or FileObserver.CLOSE_WRITE
    }
}
