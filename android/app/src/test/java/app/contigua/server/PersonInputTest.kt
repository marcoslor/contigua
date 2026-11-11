package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The panel's own input devices (docs/specs/controls.md CTRL-11): which raw
 * events mean the person touched the phone, which are the power key's (the power
 * watch's edge), and which are nothing. Contigua's own pokes and injected
 * input never reach these nodes, so the table also pins that a keep-alive step
 * cannot be read as the person.
 */
class PersonInputTest {

    // `<linux/input-event-codes.h>`
    private val evSyn = 0x00
    private val evKey = 0x01
    private val evAbs = 0x03
    private val absMtTrackingId = 0x39
    private val absMtPositionX = 0x35
    private val btnToolFinger = 0x145
    private val btnToolPen = 0x140
    private val btnTouch = 0x14a
    private val keyVolumeDown = 114
    private val keyPower = 116
    private val keySleep = 142
    private val keyWakeup = 143
    private val keyHome = 172

    @Test
    fun `a finger going down is a touch`() {
        assertEquals(PanelInput.TOUCH, panelInput(evKey, btnTouch, 1))
        assertEquals(PanelInput.TOUCH, panelInput(evKey, btnToolFinger, 1))
        assertEquals(PanelInput.TOUCH, panelInput(evAbs, absMtTrackingId, 0))
    }

    @Test
    fun `a finger going up or a bare position is not a use on its own`() {
        assertNull("a release is not a new use", panelInput(evKey, btnTouch, 0))
        assertNull("the tracking id -1 ends a contact", panelInput(evAbs, absMtTrackingId, -1))
        assertNull("a position sample alone is not a contact", panelInput(evAbs, absMtPositionX, 700))
        assertNull("a sync is not an event", panelInput(evSyn, 0, 0))
    }

    @Test
    fun `the power key belongs to the power watch`() {
        assertEquals(PanelInput.POWER, panelInput(evKey, keyPower, 1))
        assertEquals(PanelInput.POWER, panelInput(evKey, keySleep, 1))
        assertEquals(PanelInput.POWER, panelInput(evKey, keyWakeup, 1))
    }

    @Test
    fun `another key is the person's use`() {
        assertEquals(PanelInput.KEY, panelInput(evKey, keyVolumeDown, 1))
        assertEquals(PanelInput.KEY, panelInput(evKey, keyHome, 1))
    }

    @Test
    fun `a pen hovering over the panel is not a finger`() {
        assertNull(panelInput(evKey, btnToolPen, 1))
    }

    // --- the device table -------------------------------------------------

    private val devices = """
        I: Bus=0018 Vendor=04f3 Product=2d4a Version=0100
        N: Name="sec_touchscreen"
        P: Phys=i2c-3
        S: Sysfs=/devices/platform/soc/i2c-3/input/input2
        U: Uniq=
        H: Handlers=event2 cpufreq
        B: PROP=2
        B: EV=b

        I: Bus=0019 Vendor=0001 Product=0001 Version=0100
        N: Name="gpio-keys"
        P: Phys=gpio-keys/input0
        S: Sysfs=/devices/platform/gpio-keys/input/input1
        U: Uniq=
        H: Handlers=event1
        B: PROP=0
        B: EV=3
    """.trimIndent()

    @Test
    fun `every input device is named by its kernel node`() {
        assertEquals(
            listOf(
                InputEventNode("/dev/input/event2", "sec_touchscreen"),
                InputEventNode("/dev/input/event1", "gpio-keys"),
            ),
            inputEventNodes(devices),
        )
    }

    @Test
    fun `a device without a handler is skipped`() {
        assertEquals(emptyList<InputEventNode>(), inputEventNodes("N: Name=\"nothing\"\nP: Phys=none"))
    }

    // --- one struct input_event -------------------------------------------

    /** One event as the kernel writes it: timeval (2 x 8 bytes) + type + code + value. */
    private fun event(type: Int, code: Int, value: Int, at: Int = 0): ByteArray {
        val bytes = ByteArray(at + INPUT_EVENT_BYTES)
        val typeAt = at + 2 * Long.SIZE_BYTES
        bytes[typeAt] = type.toByte()
        bytes[typeAt + 2] = code.toByte()
        bytes[typeAt + 3] = (code shr 8).toByte()
        bytes[typeAt + 4] = value.toByte()
        bytes[typeAt + 5] = (value shr 8).toByte()
        bytes[typeAt + 6] = (value shr 16).toByte()
        bytes[typeAt + 7] = (value shr 24).toByte()
        return bytes
    }

    @Test
    fun `a raw event decodes to its type, code and value`() {
        val decoded = decodeInputEvent(event(evAbs, absMtTrackingId, 42))
        assertEquals(RawInputEvent(evAbs, absMtTrackingId, 42), decoded)
    }

    @Test
    fun `a negative value survives the decode`() {
        assertEquals(-1, decodeInputEvent(event(evAbs, absMtTrackingId, -1)).value)
    }

    @Test
    fun `the decode starts where the caller says`() {
        val bytes = event(evKey, keyVolumeDown, 1, at = 24)
        val decoded = decodeInputEvent(bytes, offset = 24)
        assertEquals(RawInputEvent(evKey, keyVolumeDown, 1), decoded)
        assertEquals(PanelInput.KEY, panelInput(decoded.type, decoded.code, decoded.value))
    }
}
