package dev.pocketdeck.direct

import android.Manifest

/**
 * DIRECT-11's permission choice: API 33+ asks `NEARBY_WIFI_DEVICES`, API 30–32
 * asks location (minSdk is 30). The person-facing sentence and the row are P4's.
 */
object DirectPermissions {
    const val NEARBY = Manifest.permission.NEARBY_WIFI_DEVICES
    const val LOCATION = Manifest.permission.ACCESS_FINE_LOCATION

    fun required(sdk: Int): String = if (sdk >= 33) NEARBY else LOCATION

    /** The one runtime permission this API level needs, as the checker reports it. */
    fun granted(sdk: Int, check: (String) -> Boolean): Boolean = check(required(sdk))
}
