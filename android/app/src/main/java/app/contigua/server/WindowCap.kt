package app.contigua.server

/**
 * WIN-32: how many app windows one phone runs at once, and what counts.
 *
 * The cap is per phone and covers every app stream — each is a virtual display
 * with its own encoder, and the encoder is what the phone pays for
 * The Phone Mirror has a separate encoder and is
 * never counted; neither is a stream that has not got as far as naming its
 * content.
 *
 * Pure: the session counts its streams and asks this, so the refusal is a unit
 * test and the number stays in one place.
 */
internal object WindowCap {

    /** The phone's default until a real phone measures otherwise (WIN-32). */
    const val MAX_WINDOWS = 4

    /** Whether this stream occupies one of the [MAX_WINDOWS]. */
    fun counted(content: WindowContent?): Boolean = when (content) {
        is WindowContent.App, is WindowContent.Link -> true
        WindowContent.Phone, null -> false
    }

    /** True when one more app stream may open with [openCounted] of them already open. */
    fun allows(openCounted: Int): Boolean = openCounted < MAX_WINDOWS
}
