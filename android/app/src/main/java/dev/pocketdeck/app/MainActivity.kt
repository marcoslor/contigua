package dev.pocketdeck.app

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import dev.pocketdeck.R
import rikka.shizuku.Shizuku

/** The only screen: Shizuku grant, the on/off switch, status and paired Macs. */
class MainActivity : Activity() {

    private lateinit var shizukuStatus: TextView
    private lateinit var grantButton: Button
    private lateinit var allowSwitch: Switch
    private lateinit var serverStatus: TextView
    private lateinit var connectedMac: TextView
    private lateinit var pairedContainer: LinearLayout
    private lateinit var pairingBox: LinearLayout
    private lateinit var pairingText: TextView

    private val stateListener: () -> Unit = { runOnUiThread { render() } }

    private val permissionListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        if (requestCode == REQUEST_SHIZUKU) {
            DeckState.shizukuGranted = grantResult == PackageManager.PERMISSION_GRANTED
            if (DeckState.shizukuGranted) DeckForegroundService.start(this)
            render()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        shizukuStatus = findViewById(R.id.shizukuStatus)
        grantButton = findViewById(R.id.grantButton)
        allowSwitch = findViewById(R.id.allowSwitch)
        serverStatus = findViewById(R.id.serverStatus)
        connectedMac = findViewById(R.id.connectedMac)
        pairedContainer = findViewById(R.id.pairedContainer)
        pairingBox = findViewById(R.id.pairingBox)
        pairingText = findViewById(R.id.pairingText)

        Shizuku.addRequestPermissionResultListener(permissionListener)

        grantButton.setOnClickListener { requestShizuku() }
        allowSwitch.setOnCheckedChangeListener { _, checked ->
            if (checked == DeckState.enabled) return@setOnCheckedChangeListener
            Prefs.setEnabled(this, checked)
            DeckState.enabled = checked
            if (checked) DeckForegroundService.start(this) else DeckForegroundService.stop(this)
            DeckState.notifyChanged()
        }
        findViewById<Button>(R.id.allowButton).setOnClickListener { answerPairing(true) }
        findViewById<Button>(R.id.denyButton).setOnClickListener { answerPairing(false) }

        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
        if (Prefs.isEnabled(this)) DeckForegroundService.start(this)
    }

    override fun onResume() {
        super.onResume()
        refreshShizuku()
        DeckState.paired = Prefs.paired(this)
        DeckState.enabled = Prefs.isEnabled(this)
        DeckState.addListener(stateListener)
    }

    override fun onPause() {
        super.onPause()
        DeckState.removeListener(stateListener)
    }

    override fun onDestroy() {
        Shizuku.removeRequestPermissionResultListener(permissionListener)
        super.onDestroy()
    }

    private fun refreshShizuku() {
        DeckState.shizukuRunning = Shizuku.pingBinder()
        DeckState.shizukuGranted = runCatching {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
    }

    private fun requestShizuku() {
        refreshShizuku()
        when {
            !DeckState.shizukuRunning -> toast(getString(R.string.shizuku_not_running))
            DeckState.shizukuGranted -> DeckForegroundService.start(this)
            else -> runCatching { Shizuku.requestPermission(REQUEST_SHIZUKU) }
                .onFailure { toast(getString(R.string.shizuku_not_running)) }
        }
    }

    private fun answerPairing(allow: Boolean) {
        val pending = DeckState.pending ?: return
        val action = if (allow) DeckForegroundService.ACTION_ALLOW else DeckForegroundService.ACTION_DENY
        startService(
            Intent(this, DeckForegroundService::class.java)
                .setAction(action)
                .putExtra(DeckForegroundService.EXTRA_REQUEST_ID, pending.requestId),
        )
        DeckState.pending = null
        DeckState.notifyChanged()
    }

    private fun render() {
        shizukuStatus.text = when {
            !DeckState.shizukuRunning -> getString(R.string.shizuku_not_running)
            DeckState.shizukuGranted -> getString(R.string.shizuku_granted)
            else -> getString(R.string.shizuku_need_grant)
        }
        grantButton.isEnabled = DeckState.shizukuRunning && !DeckState.shizukuGranted
        grantButton.visibility = if (grantButton.isEnabled || !DeckState.shizukuRunning) View.VISIBLE else View.GONE

        allowSwitch.isChecked = DeckState.enabled

        serverStatus.text = if (DeckState.port > 0) {
            getString(R.string.server_listening, DeckState.port)
        } else {
            getString(R.string.server_stopped)
        }
        connectedMac.text = DeckState.connectedMac?.let { getString(R.string.connected_to, it, DeckState.windows) }
            ?: getString(R.string.not_connected)

        renderPaired()
        renderPairing()
    }

    private fun renderPaired() {
        pairedContainer.removeAllViews()
        val macs = DeckState.paired
        if (macs.isEmpty()) {
            pairedContainer.addView(label(getString(R.string.no_paired)))
            return
        }
        for (mac in macs) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
            }
            row.addView(
                TextView(this).apply {
                    text = mac.name
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                },
            )
            row.addView(
                Button(this).apply {
                    text = getString(R.string.forget)
                    setOnClickListener {
                        startService(
                            Intent(this@MainActivity, DeckForegroundService::class.java)
                                .setAction(DeckForegroundService.ACTION_FORGET)
                                .putExtra(DeckForegroundService.EXTRA_CLIENT_ID, mac.clientId),
                        )
                    }
                },
            )
            pairedContainer.addView(row)
        }
    }

    private fun renderPairing() {
        val pending = DeckState.pending
        if (pending == null) {
            pairingBox.visibility = View.GONE
        } else {
            pairingBox.visibility = View.VISIBLE
            pairingText.text = getString(R.string.pairing_request, pending.macName, pending.code)
        }
    }

    private fun label(text: String): TextView = TextView(this).apply { this.text = text }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private companion object {
        const val REQUEST_SHIZUKU = 4001
        const val REQUEST_NOTIFICATIONS = 4002
    }
}
