package app.contigua.server

import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper

/**
 * A [Context] that claims to be `com.android.shell`, the trick that lets the
 * shell UID create virtual displays / touch system services whose CUJ checks
 * compare the caller's package name to its UID.
 */
internal class ShellContext(base: Context) : ContextWrapper(base) {

    override fun getPackageName(): String = "com.android.shell"

    override fun getOpPackageName(): String = "com.android.shell"

    override fun getAttributionSource(): AttributionSource =
        AttributionSource.Builder(2000).setPackageName("com.android.shell").build()

    override fun getApplicationContext(): Context = this

    override fun createPackageContext(packageName: String, flags: Int): Context = this
}
