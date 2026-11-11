package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * X0's phone half: the system-wide TCP counters in `/proc/net/snmp` and
 * `/proc/net/netstat`, parsed by header name (the columns move between
 * kernels), and the per-message deltas.
 */
class TCPCountersTest {

    // A real Android `cat /proc/net/snmp` shape: the header line carries the
    // names and the next line the same count of values. `RetransSegs` is
    // the 12th field, not the last.
    private val snmp = """
        Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmReqds ReasmOKs ReasmFails FragOKs FragFails FragCreates
        Ip: 2 64 200123 0 0 0 0 0 195001 188000 0 0 0 0 0 0 0 0 0
        Icmp: InMsgs InErrors InCsumErrors InDestUnreachs InTimeExcds InParmProbs InSrcQuenchs InRedirects InEchos InEchoReps InTimestamps InTimestampReps InAddrMasks InAddrMaskReps OutMsgs OutErrors OutDestUnreachs OutTimeExcds OutParmProbs OutSrcQuenchs OutRedirects OutEchos OutEchoReps OutTimestamps OutTimestampReps OutAddrMasks OutAddrMaskReps
        Icmp: 12 0 0 4 0 0 0 0 3 5 0 0 0 0 12 0 4 0 0 0 0 3 5 0 0 0 0
        Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
        Tcp: 1 200 120000 -1 812 3 1 2 4 188000 376000 37 0 5 0
        Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors InCsumErrors IgnoredMulti
        Udp: 400 2 0 390 0 0 0 0
    """.trimIndent() + "\n"

    // The same two files with TcpExt's columns in a different order: only the
    // header names may decide which value is which.
    private val netstat = """
        TcpExt: SyncookiesSent TCPTimeouts TCPLostRetransmit TCPFastRetrans DelayedACKs TCPAbortOnTimeout
        TcpExt: 0 11 3 27 940 1
    """.trimIndent() + "\n"

    private val snmpShuffled = """
        Tcp: InSegs RetransSegs InCsumErrors RtoAlgorithm CurrEstab OutSegs RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets InErrs OutRsts
        Tcp: 188000 37 0 1 4 376000 200 120000 -1 812 3 1 2 0 5
    """.trimIndent() + "\n"

    @Test
    fun retransSegmentsAreFoundByHeaderNameNotColumnIndex() {
        assertEquals(37L, ProcNetCounters.parse(snmp, "Tcp:")["RetransSegs"])
        assertEquals(37L, ProcNetCounters.parse(snmpShuffled, "Tcp:")["RetransSegs"])
        // And the neighbouring columns did not shift into it.
        assertEquals(-1L, ProcNetCounters.parse(snmp, "Tcp:")["MaxConn"])
        assertEquals(812L, ProcNetCounters.parse(snmp, "Tcp:")["ActiveOpens"])
    }

    @Test
    fun timeoutsAndLostRetransmitComeFromTheNetstatHeader() {
        val fields = ProcNetCounters.parse(netstat, "TcpExt:")
        assertEquals(11L, fields["TCPTimeouts"])
        assertEquals(3L, fields["TCPLostRetransmit"])
        assertEquals(27L, fields["TCPFastRetrans"])
    }

    @Test
    fun aMissingFileSendsNothingForItsFields() {
        // The emulator's shell may be refused these files; a missing file is
        // no measurement, not zero.
        val sample = ProcNetCounters.sample(snmp = null, netstat = null)
        assertNull(sample.retransSegs)
        assertNull(sample.timeouts)
        assertNull(sample.lostRetransmit)
        assertNull("no reading, no delta", TCPCounterDeltas().note(sample))
        assertNull(ProcNetCounters.read("/no/such/proc/file"))
    }

    @Test
    fun theCountersComeOutOfTheWholeFiles() {
        val sample = ProcNetCounters.sample(snmp = snmp, netstat = netstat)
        assertEquals(37L, sample.retransSegs)
        assertEquals(11L, sample.timeouts)
        assertEquals(3L, sample.lostRetransmit)
    }

    @Test
    fun theFirstMessageIsTheBaselineAndLaterOnesAreDeltas() {
        val deltas = TCPCounterDeltas()
        assertNull("the first message has no previous sample",
                   deltas.note(TCPCounterSample(10, 2, 1)))
        val second = deltas.note(TCPCounterSample(14, 5, 2))
        assertEquals(4L, second?.retransSegs)
        assertEquals(3L, second?.timeouts)
        assertEquals(1L, second?.lostRetransmit)
    }

    @Test
    fun statsTurningOnAgainStartsANewBaseline() {
        // Stats go off when the last window closes. The next window's first
        // message must not count every resend since the previous window.
        val deltas = TCPCounterDeltas()
        deltas.note(TCPCounterSample(10, 2, 1))
        assertEquals(4L, deltas.note(TCPCounterSample(14, 2, 1))?.retransSegs)
        deltas.restart()
        assertNull("the first message after a restart is a baseline",
                   deltas.note(TCPCounterSample(500, 90, 7)))
        assertEquals(3L, deltas.note(TCPCounterSample(503, 90, 7))?.retransSegs)
    }

    @Test
    fun aCounterThatWentBackwardsHasNoDeltaNeverNegative() {
        val deltas = TCPCounterDeltas()
        deltas.note(TCPCounterSample(10, 2, 1))
        // A reboot or a counter reset: no negative, and the other fields still
        // report their own deltas.
        val second = deltas.note(TCPCounterSample(9, 4, null))
        assertNull(second?.retransSegs)
        assertEquals(2L, second?.timeouts)
        assertNull(second?.lostRetransmit)
    }

    @Test
    fun anUnreadableTickKeepsTheLastBaseline() {
        val deltas = TCPCounterDeltas()
        deltas.note(TCPCounterSample(10, 2, 1))
        assertNull("a failed read sends nothing", deltas.note(null))
        val next = deltas.note(TCPCounterSample(13, 4, 1))
        assertEquals("the delta spans the unreadable tick", 3L, next?.retransSegs)
        assertEquals(2L, next?.timeouts)
        assertEquals(0L, next?.lostRetransmit)
    }

    @Test
    fun theWireMessageCarriesOnlyMeasuredTCPCounters() {
        val encoder = EncoderStats(1, 0, 0, 1, 0, 0, null, null, null, null)
        val send = SendSnapshot(0, 0, null, null)
        val absent = StreamStatsWire.message(1, 2_000, encoder, send)
        assertFalse(absent.containsKey("retrans"))
        assertFalse(absent.containsKey("rto"))
        assertFalse(absent.containsKey("lost_retrans"))
        val measured = StreamStatsWire.message(
            1, 2_000, encoder, send, TCPCounterSample(7, 3, 1))
        assertEquals(7L, measured["retrans"])
        assertEquals(3L, measured["rto"])
        assertEquals(1L, measured["lost_retrans"])
        // A sample where one file was unreadable carries only the other's field.
        val partial = StreamStatsWire.message(
            1, 2_000, encoder, send, TCPCounterSample(retransSegs = 2))
        assertEquals(2L, partial["retrans"])
        assertFalse(partial.containsKey("rto"))
        assertTrue(partial.containsKey("frames"))
    }
}
