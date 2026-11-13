package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** PHONE-24: Contigua's own shell-owned association, found by its fixed address. */
class CompanionAssociationTest {

    private val address = CompanionAssociation.ADDRESS

    @Test
    fun `PHONE-24 the address is locally administered and unicast`() {
        val first = address.substringBefore(':').toInt(16)
        assertEquals(2, first and 0b11)
    }

    @Test
    fun `PHONE-24 the AOSP list format names the id last`() {
        val out = """
            com.example.watch aa:bb:cc:dd:ee:ff 3
            com.android.shell fa:ce:fe:ed:f0:18 25
            com.android.shell $address 26
        """.trimIndent()
        assertEquals(26, CompanionAssociation.find(out))
    }

    @Test
    fun `PHONE-24 a list with id fields is read too`() {
        val out = "{id=31, userId=0, packageName=com.android.shell, mac=${address.uppercase()}, selfManaged=true}"
        assertEquals(31, CompanionAssociation.find(out))
    }

    @Test
    fun `PHONE-24 One UI's association records are read`() {
        // The shape `cmd companiondevice list 0` prints on One UI (Android 17),
        // with the names left out.
        val out = """
            Association{mId=4, mUserId=0, mPackageName='com.example.tv', mDeviceMacAddress=52:dc:44:15:7b:11, mDeviceProfile='null', mSelfManaged=false, mDeviceId=null}

            Association{mId=25, mUserId=0, mPackageName='com.android.shell', mDeviceMacAddress=fa:ce:fe:ed:f0:18, mDeviceProfile='android.app.role.COMPANION_DEVICE_APP_STREAMING', mSelfManaged=true, mDeviceId=null}

            Association{mId=26, mUserId=0, mPackageName='com.android.shell', mDeviceMacAddress=$address, mDeviceProfile='android.app.role.COMPANION_DEVICE_APP_STREAMING', mSelfManaged=true, mDeviceId=null, mExtraPermissions=[]}
        """.trimIndent()
        assertEquals(26, CompanionAssociation.find(out))
        assertNull(CompanionAssociation.find(out.lines().filterNot { "mId=26" in it }.joinToString("\n")))
    }

    @Test
    fun `PHONE-24 another package's or another address's association is never ours`() {
        val out = """
            com.example.streamer $address 12
            com.android.shell fa:ce:fe:ed:f0:18 25
            com.android.shellx $address 13
        """.trimIndent()
        assertNull(CompanionAssociation.find(out))
        assertNull(CompanionAssociation.find(""))
    }

    @Test
    fun `PHONE-24 the commands are positional and name only our association`() {
        assertEquals(listOf("cmd", "companiondevice", "list", "0"), CompanionAssociation.listArgv(0))
        assertEquals(
            listOf(
                "cmd", "companiondevice", "associate", "0", "com.android.shell", address,
                "android.app.role.COMPANION_DEVICE_APP_STREAMING", "true",
            ),
            CompanionAssociation.associateArgv(0),
        )
        assertEquals(
            listOf("cmd", "companiondevice", "disassociate", "0", "com.android.shell", address),
            CompanionAssociation.disassociateArgv(0),
        )
    }

    // ---- ShellAssociations with a fake shell -----------------------------

    private val ran = mutableListOf<List<String>>()
    private val logs = mutableListOf<String>()
    private var listed = ""
    private var associateExit = 0
    private var listExit = 0

    private val shell = ShellAssociations(
        user = 0,
        run = { argv ->
            ran.add(argv)
            when (argv[2]) {
                "list" -> CommandResult(listExit, listed)
                "associate" -> {
                    if (associateExit == 0) listed += "\ncom.android.shell $address 40"
                    CommandResult(associateExit, "")
                }
                "disassociate" -> CommandResult(0, "")
                else -> CommandResult(-1, "")
            }
        },
        log = { logs.add(it) },
    )

    @Test
    fun `PHONE-24 an existing association is reused, nothing is created`() {
        listed = "com.android.shell $address 26"
        assertEquals(26, shell.ensure())
        assertEquals(listOf("list"), ran.map { it[2] })
        assertEquals(listOf("association: found id=26"), logs)
    }

    @Test
    fun `PHONE-24 a missing association is created, then found`() {
        assertEquals(40, shell.ensure())
        assertEquals(listOf("list", "associate", "list"), ran.map { it[2] })
        assertEquals("association: created id=40", logs.last())
    }

    @Test
    fun `PHONE-24 a refused create answers null and logs only its exit code`() {
        associateExit = 255
        assertNull(shell.ensure())
        assertEquals(listOf("association: create failed exit=255"), logs)
    }

    @Test
    fun `PHONE-24 a failed list never creates a second association`() {
        listExit = 1
        listed = "com.android.shell $address 26"
        assertNull(shell.ensure())
        assertFalse(ran.any { it[2] == "associate" })
    }

    @Test
    fun `PHONE-24 our address in a list it cannot read is never created again`() {
        val calls = ArrayList<List<String>>()
        val logs = ArrayList<String>()
        val shell = ShellAssociations(0, { argv -> calls.add(argv); CommandResult(0, "<$address unknown shape>") }, { logs.add(it) })

        assertNull(shell.ensure())
        assertTrue(calls.none { "associate" in it })
        assertEquals(listOf("association: listed but unreadable"), logs)
    }

    @Test
    fun `PHONE-24 forget all removes ours and nothing else`() {
        listed = "com.android.shell fa:ce:fe:ed:f0:18 25\ncom.android.shell $address 26"
        assertTrue(shell.remove())
        assertEquals(CompanionAssociation.disassociateArgv(0), ran.last())
        assertEquals("association: removed id=26 exit=0", logs.last())
    }

    @Test
    fun `PHONE-24 forget all with no association runs no removal`() {
        listed = "com.android.shell fa:ce:fe:ed:f0:18 25"
        assertTrue(shell.remove())
        assertFalse(ran.any { it[2] == "disassociate" })
    }
}
