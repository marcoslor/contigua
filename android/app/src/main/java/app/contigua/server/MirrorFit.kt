package app.contigua.server

/** Sizing for the phone-screen mirror: the box turns with the screen (MirrorFrame picks the frame). */
internal object MirrorFit {

    /** After a rotation the Mac's box is still the old shape; turn it with the screen. */
    fun turnBox(box: IntSize, screen: IntSize): IntSize {
        val boxPortrait = box.h >= box.w
        val screenPortrait = screen.h >= screen.w
        return if (boxPortrait == screenPortrait) box else IntSize(box.h, box.w)
    }
}
