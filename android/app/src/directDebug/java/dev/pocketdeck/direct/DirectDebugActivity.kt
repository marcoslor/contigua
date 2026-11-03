package dev.pocketdeck.direct

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import dev.pocketdeck.app.Prefs

/**
 * The reviewer's debug-only control (brief item 7). There is no person-facing
 * UI yet: `am start` with `--es op on|off|permission|state` drives the switch,
 * asks for the runtime permission and prints the machine's current state to
 * logcat. Debug + direct builds only (`src/directDebug`).
 */
class DirectDebugActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (DirectDebugArgs.parse(intent?.getStringExtra("op"))?.op) {
            "on" -> switchOn()
            "off" -> {
                DirectRuntime.switchOff(this)
                printState()
                finish()
            }
            "permission" -> ask()
            "state" -> {
                printState()
                finish()
            }
            else -> finish()
        }
    }

    private fun switchOn() {
        Prefs.setDirectSwitch(this, true)
        if (granted()) {
            DirectRuntime.start(this)
            printState()
            finish()
        } else {
            ask()
        }
    }

    private fun ask() {
        val permission = if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        requestPermissions(arrayOf(permission), REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // A denial turns the switch back off, exactly as the person-facing row
        // will (DIRECT-11); the state line names the reason.
        if (requestCode != REQUEST) return
        if (granted()) {
            DirectRuntime.start(this)
        } else {
            Prefs.setDirectSwitch(this, false)
            DirectRuntime.stop()
        }
        printState()
        finish()
    }

    private fun granted(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    /** States only: the log is the reviewer's proof trail (R-PRIV-1). */
    private fun printState() {
        Log.i(TAG, "direct state: ${DirectRuntime.stateToken()}")
    }

    private companion object {
        const val REQUEST = 1
        const val TAG = "PocketDeckDirect"
    }
}
