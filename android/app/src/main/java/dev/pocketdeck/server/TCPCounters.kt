package dev.pocketdeck.server

import java.io.File

/**
 * X0's sender side: Linux exposes no per-socket TCP_INFO to Java, so the phone
 * reads its system-wide counters each stats tick. While a window streams the
 * stream is nearly all of the phone's TCP traffic, so these are a close
 * stand-in; the `/proc/net` files may be unreadable to the shell on some
 * builds, which is "no measurement", never zero.
 */
internal data class TCPCounterSample(
    val retransSegs: Long? = null,
    val timeouts: Long? = null,
    val lostRetransmit: Long? = null,
)

internal object ProcNetCounters {
    private const val SNMP = "/proc/net/snmp"
    private const val NETSTAT = "/proc/net/netstat"

    fun read(path: String): String? = runCatching { File(path).readText() }.getOrNull()

    /** One whole system's reading; an unreadable file leaves its field absent. */
    fun sample(snmp: String? = read(SNMP),
               netstat: String? = read(NETSTAT)): TCPCounterSample {
        val tcp = snmp?.let { parse(it, "Tcp:") }.orEmpty()
        val ext = netstat?.let { parse(it, "TcpExt:") }.orEmpty()
        return TCPCounterSample(
            retransSegs = tcp["RetransSegs"],
            timeouts = ext["TCPTimeouts"],
            lostRetransmit = ext["TCPLostRetransmit"],
        )
    }

    /**
     * One `/proc/net` block as header-name to value. The two lines carry the
     * same number of fields; kernels add and reorder columns, so only the
     * header names may decide which value is which.
     */
    fun parse(text: String, prefix: String): Map<String, Long> {
        val lines = text.lineSequence().filter { it.startsWith(prefix) }.toList()
        if (lines.size < 2) return emptyMap()
        val header = fields(lines[0].removePrefix(prefix))
        val values = fields(lines[1].removePrefix(prefix))
        val out = HashMap<String, Long>(header.size)
        for (index in header.indices) {
            val value = values.getOrNull(index)?.toLongOrNull() ?: continue
            out[header[index]] = value
        }
        return out
    }

    private fun fields(line: String): List<String> =
        line.split(' ', '\t').filter { it.isNotEmpty() }
}

/**
 * The last reading, so each `stream.stats` message carries the delta since the
 * previous one. A counter that went backwards (a reset) has no delta rather
 * than a negative; an unreadable tick sends nothing and keeps the baseline.
 */
internal class TCPCounterDeltas {
    private var previous: TCPCounterSample? = null

    fun note(sample: TCPCounterSample?): TCPCounterSample? {
        if (sample == null) return null
        val last = previous
        previous = sample
        if (last == null) return null
        return TCPCounterSample(
            retransSegs = delta(sample.retransSegs, last.retransSegs),
            timeouts = delta(sample.timeouts, last.timeouts),
            lostRetransmit = delta(sample.lostRetransmit, last.lostRetransmit),
        )
    }

    private fun delta(current: Long?, previous: Long?): Long? {
        if (current == null || previous == null || current < previous) return null
        return current - previous
    }
}
