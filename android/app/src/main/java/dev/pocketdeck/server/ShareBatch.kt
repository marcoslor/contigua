package dev.pocketdeck.server

import java.io.File

/**
 * One gesture's files (SHARE-17): the Mac sends them one at a time, each with
 * its position on `drop.start`, and the phone shares the whole batch once,
 * after the last one lands. A batch over the share cache's five is saved in
 * Downloads/PocketDeck but never offered.
 */
class ShareBatch(
    private val maxShare: Int = 5,
    private val share: (files: List<Pair<File, String>>, target: String?) -> Unit,
) {
    private var target: String? = null
    private var count = 0
    private var next = 1
    private var files = mutableListOf<Pair<File, String>>()

    fun landed(file: File, mime: String, target: String?, index: Int, count: Int) {
        // A repeated first file, another target or another batch length starts
        // over: the old one lost a file and can never complete.
        if (index <= 1 || target != this.target || count != this.count) reset(target, count)
        if (index != next) {
            // Out of order (a lost landing): no half batch is kept.
            files.clear()
            next = index
        }
        files += file to mime
        next += 1
        if (files.size == count) {
            val done = files.toList()
            val doneTarget = target
            reset(target, count)
            if (count in 1..maxShare) share(done, doneTarget)
        }
    }

    private fun reset(target: String?, count: Int) {
        this.target = target
        this.count = count
        this.next = 1
        files = mutableListOf()
    }
}
