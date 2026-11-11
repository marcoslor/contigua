package app.contigua.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * Advertises the server over DNS-SD as `_contigua._tcp` with the TXT records
 * from docs/PROTOCOL.md: v, id, name, model.
 */
class NsdAdvertiser(context: Context) {

    private val nsdManager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.RegistrationListener? = null

    fun advertise(port: Int, deviceId: String, name: String, model: String) {
        stop()
        val info = NsdServiceInfo().apply {
            serviceName = "Contigua $name"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", "1")
            setAttribute("id", deviceId)
            setAttribute("name", name)
            setAttribute("model", model)
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "mdns registered: ${info.serviceName}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.i(TAG, "mdns registration failed: $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        listener = l
        try {
            nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Throwable) {
            Log.i(TAG, "mdns register threw: ${e.message}")
            listener = null
        }
    }

    fun stop() {
        val l = listener ?: return
        listener = null
        runCatching { nsdManager.unregisterService(l) }
    }

    private companion object {
        const val TAG = "ContiguaApp"
        const val SERVICE_TYPE = "_contigua._tcp"
    }
}
