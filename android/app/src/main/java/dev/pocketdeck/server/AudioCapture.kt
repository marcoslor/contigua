package dev.pocketdeck.server

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import dev.pocketdeck.proto.Frames

/**
 * Device-wide audio capture over REMOTE_SUBMIX.
 *
 * Opening a REMOTE_SUBMIX input from the shell UID (which holds
 * CAPTURE_AUDIO_OUTPUT) makes the framework route media playback to the
 * submix output instead of the speaker, so the phone goes silent while we
 * stream and no AudioPolicy is needed. Approach adapted from scrcpy's
 * "output" audio source (Apache-2.0).
 *
 * The submix device keeps its own music volume index (often mid-scale), which
 * attenuates the capture; once routing has switched we raise that index only.
 */
internal class AudioCapture(
    private val ctx: Context,
    private val log: (String) -> Unit,
) : AudioCaptureLayer {

    private companion object {
        const val SAMPLE_RATE = 48000
        const val CHANNELS = 2
        const val FRAME_MS = 20
        const val BITRATE_OPUS = 64_000
        const val BITRATE_AAC = 64_000
        const val MIME_OPUS = "audio/opus"
        const val MIME_AAC = "audio/mp4a-latm"
        /** 20 ms stereo 16-bit at 48 kHz. */
        const val CHUNK_BYTES = SAMPLE_RATE * CHANNELS * 2 * FRAME_MS / 1000
        const val MAX_AHEAD_NS = 40_000_000L
        const val OUTPUT_WAIT_US = 10_000L
        const val MAX_BEHIND_NS = 200_000_000L
    }

    @Volatile private var running = false
    @Volatile private var thread: Thread? = null
    @Volatile private var record: AudioRecord? = null
    @Volatile private var codec: MediaCodec? = null
    override val isRunning: Boolean get() = running

    @Synchronized
    override fun start(sink: AudioSink, preferredCodecs: List<Int>) {
        if (running) return
        val wantOpus = preferredCodecs.isEmpty() || preferredCodecs.contains(Frames.CODEC_OPUS)
        val wantAac = preferredCodecs.isEmpty() || preferredCodecs.contains(Frames.CODEC_AAC)
        val mime: String
        val codecId: Int
        if (wantOpus && hasEncoder(MIME_OPUS)) {
            mime = MIME_OPUS
            codecId = Frames.CODEC_OPUS
        } else if (wantAac && hasEncoder(MIME_AAC)) {
            mime = MIME_AAC
            codecId = Frames.CODEC_AAC
        } else {
            log("audio: no encoder for $preferredCodecs")
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            log("audio: bad min buffer $minBuf")
            return
        }
        val rec = try {
            // The record's attribution must be uid 2000 + com.android.shell (from
            // the ShellContext); our own package at the shell UID is rejected.
            AudioRecord.Builder()
                .apply { if (Build.VERSION.SDK_INT >= 31) setContext(ctx) }
                .setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBuf, CHUNK_BYTES * 4))
                .build()
        } catch (t: Throwable) {
            log("audio: record init failed: ${t.message}")
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            log("audio: record not initialized")
            runCatching { rec.release() }
            return
        }
        val enc = try {
            MediaCodec.createEncoderByType(mime)
        } catch (t: Throwable) {
            log("audio: no $mime encoder: ${t.message}")
            runCatching { rec.release() }
            return
        }
        try {
            val format = MediaFormat.createAudioFormat(mime, SAMPLE_RATE, CHANNELS)
            format.setInteger(MediaFormat.KEY_BIT_RATE, if (codecId == Frames.CODEC_OPUS) BITRATE_OPUS else BITRATE_AAC)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, CHUNK_BYTES * 2)
            if (codecId == Frames.CODEC_AAC) {
                runCatching {
                    format.setInteger(
                        MediaFormat.KEY_AAC_PROFILE,
                        MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                    )
                }
            }
            runCatching { format.setInteger(MediaFormat.KEY_PRIORITY, 0) }
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
        } catch (t: Throwable) {
            log("audio: encoder configure failed: ${t.message}")
            runCatching { enc.release() }
            runCatching { rec.release() }
            return
        }
        running = true
        record = rec
        codec = enc
        sink.onAudioConfig(codecId, SAMPLE_RATE, CHANNELS, FRAME_MS, ByteArray(0))
        log("audio: capturing codec=$codecId ($mime)")
        thread = Thread({ loop(sink, codecId, rec, enc) }, "pocketdeck-audio").also { it.start() }
        runCatching { rec.startRecording() }
            .onSuccess { Thread(::raiseSubmixVolume, "pocketdeck-audio-vol").start() }
            .onFailure {
                log("audio: startRecording failed: ${it.message}")
                stop()
            }
    }

    @Synchronized
    override fun stop() {
        if (!running && thread == null) return
        running = false
        runCatching { record?.stop() }
        runCatching { Thread.sleep(20) }
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        runCatching { record?.release() }
        codec = null
        record = null
        val t = thread
        thread = null
        if (t != null && t !== Thread.currentThread()) runCatching { t.join(1000) }
        log("audio: stopped")
    }

    private fun loop(sink: AudioSink, codecId: Int, rec: AudioRecord, enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        val chunk = ByteArray(CHUNK_BYTES)
        var sentAacSetup = false
        var clockBaseNs = 0L
        var producedNs = 0L
        while (running) {
            val n = try {
                rec.read(chunk, 0, chunk.size)
            } catch (_: Throwable) {
                break
            }
            if (n <= 0) continue
            val nowNs = SystemClock.elapsedRealtimeNanos()
            // With nothing playing, the submix input synthesizes silence faster
            // than realtime; drop chunks that run ahead of the wall clock so the
            // Mac's queue (and so latency) cannot grow.
            if (clockBaseNs == 0L || clockBaseNs + producedNs < nowNs - MAX_BEHIND_NS) {
                clockBaseNs = nowNs
                producedNs = 0L
            }
            val chunkNs = n * 1_000_000_000L / (SAMPLE_RATE * CHANNELS * 2)
            if (clockBaseNs + producedNs + chunkNs > nowNs + MAX_AHEAD_NS) continue
            producedNs += chunkNs
            val ptsUs = nowNs / 1000
            try {
                val idx = enc.dequeueInputBuffer(10_000)
                if (idx >= 0) {
                    val buf = enc.getInputBuffer(idx) ?: continue
                    buf.clear()
                    buf.put(chunk, 0, n)
                    enc.queueInputBuffer(idx, 0, n, ptsUs, 0)
                }
            } catch (_: Throwable) {
                break
            }
            // Wait briefly for this chunk's packet so it leaves now, not one read later.
            var waitUs = OUTPUT_WAIT_US
            while (running) {
                val out = try {
                    enc.dequeueOutputBuffer(info, waitUs).also { waitUs = 0 }
                } catch (_: Throwable) {
                    break
                }
                if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    if (codecId == Frames.CODEC_AAC && !sentAacSetup) {
                        val asc = runCatching {
                            val fmt = enc.outputFormat
                            val csd = fmt.getByteBuffer("csd-0") ?: return@runCatching null
                            val dup = csd.duplicate()
                            val bytes = ByteArray(dup.remaining())
                            dup.get(bytes)
                            bytes
                        }.getOrNull()
                        if (asc != null) {
                            sentAacSetup = true
                            sink.onAudioConfig(codecId, SAMPLE_RATE, CHANNELS, FRAME_MS, asc)
                        }
                    }
                    continue
                }
                if (out < 0) break
                try {
                    val buf = enc.getOutputBuffer(out)
                    if (buf != null && info.size > 0 &&
                        (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                    ) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        val data = ByteArray(info.size)
                        buf.get(data)
                        sink.onAudioFrame(info.presentationTimeUs, data)
                    }
                } catch (_: Throwable) {
                } finally {
                    runCatching { enc.releaseOutputBuffer(out, false) }
                }
                if (info.size == 0) break
            }
        }
    }

    private fun hasEncoder(mime: String): Boolean = runCatching {
        val list = android.media.MediaCodecList(android.media.MediaCodecList.ALL_CODECS)
        list.codecInfos.any { info: MediaCodecInfo ->
            info.isEncoder && runCatching { info.getCapabilitiesForType(mime) }.getOrNull() != null
        }
    }.getOrDefault(false)

    /**
     * Sets STREAM_MUSIC to max while media is routed to the submix, which
     * changes the submix device's index and leaves the speaker's untouched.
     * AudioManager.getDevicesForAttributes is a hidden API, hence reflection.
     */
    private fun raiseSubmixVolume() = runCatching {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
        val devicesFor = AudioManager::class.java.getMethod("getDevicesForAttributes", AudioAttributes::class.java)
        val deadline = SystemClock.uptimeMillis() + 2000
        while (running && SystemClock.uptimeMillis() < deadline) {
            val devices = devicesFor.invoke(am, media) as List<*>
            val routed = devices.any {
                it!!.javaClass.getMethod("getType").invoke(it) == AudioDeviceInfo.TYPE_REMOTE_SUBMIX
            }
            if (routed) {
                am.setStreamVolume(AudioManager.STREAM_MUSIC, am.getStreamMaxVolume(AudioManager.STREAM_MUSIC), 0)
                return@runCatching
            }
            Thread.sleep(20)
        }
        log("audio: media not routed to submix")
    }.onFailure { log("audio: submix volume: ${it.message}") }
}
