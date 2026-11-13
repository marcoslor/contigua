package app.contigua.server

import android.content.Context
import android.hardware.display.VirtualDisplay
import android.hardware.display.VirtualDisplayConfig
import android.os.IBinder
import java.lang.reflect.InvocationTargetException

/**
 * One platform virtual device (`VirtualDeviceManager.VirtualDevice`), reached
 * by reflection: its calls are system APIs, and the service is the shell user
 * with `CREATE_VIRTUAL_DEVICE` (docs/specs/app-windows.md WIN-75).
 */
internal class AndroidWindowDevice(
    private val device: Any,
    val deviceId: Int,
    /** The panel's refresh floor, held for the device's life (WIN-76). */
    private val floor: RefreshFloor,
) {

    /** A display of this device's own group; throws when the device is gone. */
    fun createDisplay(config: VirtualDisplayConfig): VirtualDisplay {
        val method = device.javaClass.methods.firstOrNull {
            it.name == "createVirtualDisplay" &&
                it.parameterTypes.size == 3 &&
                it.parameterTypes[0] == VirtualDisplayConfig::class.java
        } ?: throw NoSuchMethodException("VirtualDevice.createVirtualDisplay(VirtualDisplayConfig, Executor, Callback)")
        val display = unwrap { method.invoke(device, config, null, null) } as? VirtualDisplay
        return display ?: throw IllegalStateException("VirtualDevice.createVirtualDisplay returned null")
    }

    fun close() {
        floor.drop()
        runCatching { device.javaClass.getMethod("close").invoke(device) }
    }

    companion object {
        private const val MANAGER = "android.companion.virtual.VirtualDeviceManager"
        private const val IFACE = "android.companion.virtual.IVirtualDeviceManager"
        private const val PARAMS = "android.companion.virtual.VirtualDeviceParams"

        /** The device's name in the platform's own lists; never shown to the person. */
        const val NAME = "Contigua"

        /** `VirtualDeviceParams.POLICY_TYPE_RECENTS`, `POLICY_TYPE_CLIPBOARD` and `DEVICE_POLICY_CUSTOM`. */
        const val POLICY_TYPE_RECENTS = 2
        const val POLICY_TYPE_CLIPBOARD = 4
        const val DEVICE_POLICY_CUSTOM = 1

        /**
         * The custom policies, by the name the log uses: recents (the window
         * apps' tasks are not listed in the phone's own Recents) and the
         * clipboard (shared with the phone's, so paste works both ways).
         */
        private val POLICIES = listOf("recents" to POLICY_TYPE_RECENTS, "clipboard" to POLICY_TYPE_CLIPBOARD)

        /**
         * Makes the device from Contigua's association, or a closed reason.
         * The manager is built over [ctx] (a shell context), so the platform
         * sees `com.android.shell`, the association's owner.
         */
        fun make(ctx: Context, associations: ShellAssociations, log: (String) -> Unit): DeviceMake<AndroidWindowDevice> {
            val binder: IBinder = Hidden.binder("virtualdevice") ?: return DeviceMake.Failed("no_service")
            val manager = runCatching {
                val service = Class.forName("$IFACE\$Stub").getMethod("asInterface", IBinder::class.java)
                    .invoke(null, binder)
                val ctor = Class.forName(MANAGER).getDeclaredConstructor(Class.forName(IFACE), Context::class.java)
                ctor.isAccessible = true
                ctor.newInstance(service, ctx)
            }.getOrElse {
                log("windowdevice: no manager (${failureClasses(it)})")
                return DeviceMake.Failed("no_service")
            }
            val association = associations.ensure() ?: return DeviceMake.Failed("no_association")
            val (params, atBuild) = runCatching { params() }.getOrElse {
                log("windowdevice: params refused (${failureClasses(it)})")
                return DeviceMake.Failed("refused")
            }
            val device = runCatching {
                val create = manager.javaClass.methods.first {
                    it.name == "createVirtualDevice" && it.parameterTypes.size == 2 &&
                        it.parameterTypes[0] == Hidden.T_INT
                }
                unwrap { create.invoke(manager, association, params) }
                    ?: throw IllegalStateException("createVirtualDevice returned null")
            }.getOrElse {
                log("windowdevice: create refused association=$association (${failureClasses(it)})")
                return DeviceMake.Failed("refused")
            }
            val id = runCatching { device.javaClass.getMethod("getDeviceId").invoke(device) as Int }.getOrDefault(-1)
            // A policy is set from the start where the params carry it; a build
            // that only takes it on a live device gets it here. The log names
            // which call took it, not whether the platform honours it: the
            // paste check on the phone is the proof (WIN-75).
            val policies = POLICIES.joinToString(" ") { (name, type) ->
                val how = when {
                    type in atBuild -> "params"
                    runCatching {
                        device.javaClass.getMethod("setDevicePolicy", Hidden.T_INT, Hidden.T_INT)
                            .invoke(device, type, DEVICE_POLICY_CUSTOM)
                    }.isSuccess -> "live"
                    else -> "default"
                }
                "$name=$how"
            }
            val floor = RefreshFloor(AndroidRefreshFloor::acquire)
            log("windowdevice: device $id made association=$association $policies ${floor.hold()}")
            return DeviceMake.Made(AndroidWindowDevice(device, id, floor))
        }

        /** The params, and the policy types they took. */
        private fun params(): Pair<Any, Set<Int>> {
            val builderClass = Class.forName("$PARAMS\$Builder")
            val builder = builderClass.getDeclaredConstructor().newInstance()
            builderClass.getMethod("setName", String::class.java).invoke(builder, NAME)
            val set = builderClass.getMethod("setDevicePolicy", Hidden.T_INT, Hidden.T_INT)
            val took = POLICIES.map { it.second }.filter { type ->
                runCatching { set.invoke(builder, type, DEVICE_POLICY_CUSTOM) }.isSuccess
            }.toSet()
            val params = builderClass.getMethod("build").invoke(builder)
                ?: throw IllegalStateException("VirtualDeviceParams.Builder.build returned null")
            return params to took
        }

        private inline fun unwrap(call: () -> Any?): Any? = try {
            call()
        } catch (e: InvocationTargetException) {
            throw e.targetException ?: e
        }
    }
}
