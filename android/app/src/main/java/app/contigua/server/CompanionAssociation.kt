package app.contigua.server

/**
 * Contigua's own companion association, the one its virtual device is made
 * from (docs/specs/phone-app.md PHONE-24).
 *
 * The app-streaming role needs a permission only system apps hold, so an
 * association owned by `app.contigua` is refused (`Package does not qualify for
 * the role`). The service runs as the shell user, which may own one, so the
 * association is the shell's: self-managed, profile
 * `COMPANION_DEVICE_APP_STREAMING`, and known by a fixed locally administered
 * address that no real device carries. Every other association on the phone
 * is someone else's and is never touched.
 *
 * Pure: the commands are argument lists and the list output is parsed here;
 * [ShellAssociations] runs them.
 */
internal object CompanionAssociation {

    /** Locally administered (bit 1 of the first octet), unicast: never a real radio's. */
    const val ADDRESS = "02:c0:4e:00:00:01"
    const val PACKAGE = "com.android.shell"
    const val PROFILE = "android.app.role.COMPANION_DEVICE_APP_STREAMING"

    fun listArgv(user: Int): List<String> = listOf("cmd", "companiondevice", "list", user.toString())

    /**
     * Positional, as the platform's shell command reads them: the flag form its
     * help text shows is refused on One UI ("--profile was not a valid MAC
     * address"). The last argument makes it self-managed.
     */
    fun associateArgv(user: Int): List<String> =
        listOf("cmd", "companiondevice", "associate", user.toString(), PACKAGE, ADDRESS, PROFILE, "true")

    fun disassociateArgv(user: Int): List<String> =
        listOf("cmd", "companiondevice", "disassociate", user.toString(), PACKAGE, ADDRESS)

    /** `id=31` or One UI's `mId=26`, never `mUserId=0`. */
    private val idField = Regex("""(?<![A-Za-z])m?[iI]d\s*=\s*(\d+)""")
    private val number = Regex("""^\d+$""")

    /**
     * The id of the shell's association with [ADDRESS] in `cmd companiondevice
     * list` output, or null. AOSP prints `<package> <address> <id>` per line;
     * a build that prints `id=<n>` fields, or One UI's
     * `Association{mId=26, …, mPackageName='com.android.shell',
     * mDeviceMacAddress=…}`, is read too. A line must name both the shell
     * package and the address as whole tokens (quotes stripped).
     */
    fun find(listOutput: String): Int? {
        for (raw in listOutput.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            val tokens = line.split(Regex("""[\s,;{}\[\]]+""")).filter { it.isNotEmpty() }
            val values = tokens.map { it.substringAfter('=').trim('\'', '"') }
            if (values.none { it == PACKAGE }) continue
            if (values.none { it.equals(ADDRESS, ignoreCase = true) }) continue
            idField.find(line)?.let { return it.groupValues[1].toIntOrNull() }
            return tokens.lastOrNull { number.matches(it) }?.toIntOrNull()
        }
        return null
    }
}

/** One finished shell command: its exit code (-1 when it never ran) and output. */
internal data class CommandResult(val exit: Int, val output: String)

/**
 * Finds, makes and removes the association with the shell's own `cmd
 * companiondevice` (the service is uid 2000). The log carries the step, the
 * association id and exit codes only, never the command's output: a list names
 * other apps' associations.
 */
internal class ShellAssociations(
    private val user: Int,
    private val run: (List<String>) -> CommandResult,
    private val log: (String) -> Unit,
) {

    /** The association's id, made first when the shell owns none; null when it cannot be. */
    fun ensure(): Int? {
        // A list that fails says nothing about what exists: never create then.
        val before = list() ?: return null
        CompanionAssociation.find(before)?.let { id ->
            log("association: found id=$id")
            return id
        }
        // Our address is listed but its record could not be read: a list
        // format this parser does not know. Never make a second one.
        if (before.contains(CompanionAssociation.ADDRESS, ignoreCase = true)) {
            log("association: listed but unreadable")
            return null
        }
        val made = run(CompanionAssociation.associateArgv(user))
        if (made.exit != 0) {
            log("association: create failed exit=${made.exit}")
            return null
        }
        val id = list()?.let { CompanionAssociation.find(it) }
        log(if (id != null) "association: created id=$id" else "association: created but not listed")
        return id
    }

    /** Forget All Macs: removes Contigua's association if there is one (PHONE-24). */
    fun remove(): Boolean {
        val listed = list() ?: return false
        val id = CompanionAssociation.find(listed) ?: run {
            log("association: none to remove")
            return true
        }
        val done = run(CompanionAssociation.disassociateArgv(user))
        log("association: removed id=$id exit=${done.exit}")
        return done.exit == 0
    }

    /** The list's output, or null when the command failed (logged with its exit code). */
    private fun list(): String? {
        val listed = run(CompanionAssociation.listArgv(user))
        if (listed.exit != 0) {
            log("association: list failed exit=${listed.exit}")
            return null
        }
        return listed.output
    }

    companion object {
        private const val TIMEOUT_S = 10L

        /** Runs [argv] as this process (the shell user), bounded. */
        fun runCommand(argv: List<String>): CommandResult = runCatching {
            val process = ProcessBuilder(argv).redirectErrorStream(true).start()
            val output = StringBuilder()
            val reader = Thread {
                runCatching { process.inputStream.bufferedReader().use { output.append(it.readText()) } }
            }.also { it.isDaemon = true; it.start() }
            if (!process.waitFor(TIMEOUT_S, java.util.concurrent.TimeUnit.SECONDS)) {
                process.destroyForcibly()
                return CommandResult(-1, "")
            }
            reader.join(1_000)
            CommandResult(process.exitValue(), output.toString())
        }.getOrDefault(CommandResult(-1, ""))
    }
}
