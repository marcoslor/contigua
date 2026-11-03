package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * DIRECT-11's permission choice: `NEARBY_WIFI_DEVICES` from API 33, location
 * below it (minSdk 30). The person-facing row and its sentence are P4's.
 */
class DirectPermissionTest {

    @Test
    fun api33AndAboveAskNearbyDevices() {
        assertEquals(DirectPermissions.NEARBY, DirectPermissions.required(33))
        assertEquals(DirectPermissions.NEARBY, DirectPermissions.required(36))
    }

    @Test
    fun api30To32AskFineLocation() {
        assertEquals(DirectPermissions.LOCATION, DirectPermissions.required(30))
        assertEquals(DirectPermissions.LOCATION, DirectPermissions.required(32))
    }

    @Test
    fun grantedFollowsTheOnePermissionThatVersionNeeds() {
        val asked = mutableListOf<String>()
        assertTrue(
            DirectPermissions.granted(34) { permission ->
                asked.add(permission)
                true
            },
        )
        assertEquals(listOf(DirectPermissions.NEARBY), asked)
        asked.clear()
        assertFalse(
            DirectPermissions.granted(31) { permission ->
                asked.add(permission)
                false
            },
        )
        assertEquals(listOf(DirectPermissions.LOCATION), asked)
    }
}
