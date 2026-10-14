package dev.pocketdeck.server

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.SystemClock
import dev.pocketdeck.proto.Frames

/**
 * Device-wide audio capture over REMOTE_SUBMIX.
 *
 * Proven on API 36 at shell UID: AudioPlaybackCapture needs a MediaProjection
 * (MANAGE_MEDIA_PROJECTION, signature) which the shell lacks, while the shell
 * holds CAPTURE_AUDIO_OUTPUT + MANAGE_AUDIO_POLICY + MODIFY_AUDIO_ROUTING and
 * REMOTE_SUBMIX AudioRecord init/start works. Routing media usages to the
 * submix silences the phone speaker for those usages.
 *
 * AudioMix/AudioMixingRule/AudioPolicy are hidden (@SystemApi), so the policy
 * below is built reflectively (same pattern as PanelPower/Hidden elsewhere).
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
    }

    @Volatile private var running = false
    @Volatile private var thread: Thread? = null
    @Volatile private var policy: Any? = null
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
        if (!registerPolicy()) {
            log("audio: policy registration failed")
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            log("audio: bad min buffer $minBuf")
            unregisterPolicy()
            return
        }
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.REMOTE_SUBMIX, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, CHUNK_BYTES * 4),
            )
        } catch (t: Throwable) {
            log("audio: record init failed: ${t.message}")
            unregisterPolicy()
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            log("audio: record not initialized")
            runCatching { rec.release() }
            unregisterPolicy()
            return
        }
        val enc = try {
            MediaCodec.createEncoderByType(mime)
        } catch (t: Throwable) {
            log("audio: no $mime encoder: ${t.message}")
            runCatching { rec.release() }
            unregisterPolicy()
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
            unregisterPolicy()
            return
        }
        running = true
        record = rec
        codec = enc
        sink.onAudioConfig(codecId, SAMPLE_RATE, CHANNELS, FRAME_MS, ByteArray(0))
        log("audio: capturing codec=$codecId ($mime)")
        thread = Thread({ loop(sink, codecId, rec, enc) }, "pocketdeck-audio").also { it.start() }
        runCatching { rec.startRecording() }
            .onFailure {
                log("audio: startRecording failed: ${it.message}")
                stop()
            }
    }

    @Synchronized
    override fun stop() {
        if (!running && thread == null) {
            unregisterPolicy()
            return
        }
        running = false
        runCatching { record?.stop() }
        runCatching { Thread.sleep(20) }
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        runCatching { record?.release() }
        codec = null
        record = null
        unregisterPolicy()
        val t = thread
        thread = null
        if (t != null && t !== Thread.currentThread()) runCatching { t.join(1000) }
        log("audio: stopped")
    }

    private fun loop(sink: AudioSink, codecId: Int, rec: AudioRecord, enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        val chunk = ByteArray(CHUNK_BYTES)
        var sentAacSetup = false
        while (running) {
            val n = try {
                rec.read(chunk, 0, chunk.size)
            } catch (_: Throwable) {
                break
            }
            if (n <= 0) continue
            val ptsUs = SystemClock.elapsedRealtimeNanos() / 1000
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
            while (running) {
                val out = try {
                    enc.dequeueOutputBuffer(info, 0)
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
     * Routes USAGE_MEDIA/GAME/UNKNOWN players to REMOTE_SUBMIX, reflectively:
     * AudioMix.Builder(AudioMixingRule) → setDevice(REMOTE_SUBMIX,"0") →
     * setFormat → setRouteFlags(RENDER) → AudioPolicy.Builder(ctx).addMix →
     * AudioManager.registerAudioPolicy. Constants read reflectively so the
     * build needs no hidden SDK.
     */
    private fun registerPolicy(): Boolean = runCatching {
        val ruleBuilderCl = Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
        val ruleBuilder = ruleBuilderCl.getDeclaredConstructor().newInstance()
        val addRule = ruleBuilderCl.getMethod(
            "addRule", AudioAttributes::class.java, Int::class.javaPrimitiveType,
        )
        val setTargetMixRole = runCatching {
            ruleBuilderCl.getMethod("setTargetMixRole", Int::class.javaPrimitiveType)
        }.getOrNull()
        val mixRolePlayers = runCatching {
            Class.forName("android.media.audiopolicy.AudioMixingRule")
                .getField("MIX_ROLE_PLAYERS").getInt(null)
        }.getOrDefault(0)
        val matchUsage = runCatching {
            Class.forName("android.media.audiopolicy.AudioMixingRule")
                .getField("RULE_MATCH_ATTRIBUTE_USAGE").getInt(null)
        }.getOrDefault(1)
        setTargetMixRole?.invoke(ruleBuilder, mixRolePlayers)
        for (usage in intArrayOf(
            AudioAttributes.USAGE_MEDIA, AudioAttributes.USAGE_GAME, AudioAttributes.USAGE_UNKNOWN,
        )) {
            val attr = AudioAttributes.Builder().setUsage(usage).build()
            addRule.invoke(ruleBuilder, attr, matchUsage)
        }
        val rule = ruleBuilderCl.getMethod("build").invoke(ruleBuilder)

        val mixBuilderCl = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
        val mixBuilder = mixBuilderCl.getDeclaredConstructor(rule.javaClass).newInstance(rule)
        val remoteSubmix = runCatching {
            android.media.AudioDeviceInfo::class.java.getField("TYPE_REMOTE_SUBMIX").getInt(null)
        }.getOrDefault(8)
        val routeRender = runCatching {
            Class.forName("android.media.audiopolicy.AudioMix")
                .getField("ROUTE_FLAG_RENDER").getInt(null)
        }.getOrDefault(1)
        mixBuilderCl.getMethod("setDevice", Int::class.javaPrimitiveType, String::class.java)
            .invoke(mixBuilder, remoteSubmix, "0")
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        mixBuilderCl.getMethod("setFormat", AudioFormat::class.java).invoke(mixBuilder, format)
        mixBuilderCl.getMethod("setRouteFlags", Int::class.javaPrimitiveType)
            .invoke(mixBuilder, routeRender)
        val mix = mixBuilderCl.getMethod("build").invoke(mixBuilder)

        val policyBuilderCl = Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")
        val policyBuilder = policyBuilderCl.getDeclaredConstructor(Context::class.java).newInstance(ctx)
        val audioMixClass = runCatching { Class.forName("android.media.audiopolicy.AudioMix") }.getOrNull()
            ?: (mix.javaClass.interfaces.firstOrNull() ?: mix.javaClass)
        val addMixMethod = runCatching {
            policyBuilderCl.getMethod("addMix", audioMixClass)
        }.getOrNull()
            ?: policyBuilderCl.methods.firstOrNull { it.name == "addMix" }
        addMixMethod?.let { m ->
            runCatching { m.invoke(policyBuilder, mix) }.getOrElse {
                // Fallback: try any addMix overload with the mix argument.
                policyBuilderCl.methods.firstOrNull { it.name == "addMix" }?.invoke(policyBuilder, mix)
            }
        }
        val pol = policyBuilderCl.getMethod("build").invoke(policyBuilder)
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        val register = am.javaClass.methods.firstOrNull {
            it.name == "registerAudioPolicy" && it.parameterTypes.size == 1
        } ?: return false
        val rc = (register.invoke(am, pol) as? Int) ?: -1
        if (rc == 0) {
            policy = pol
            log("audio: policy registered (media/game -> submix)")
            true
        } else {
            log("audio: registerAudioPolicy rc=$rc")
            false
        }
    }.getOrElse {
        log("audio: policy failed: ${it.message}")
        false
    }

    private fun unregisterPolicy() {
        val pol = policy ?: return
        policy = null
        val am = runCatching { ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager }?.getOrNull()
            ?: return
        val unregister = am.javaClass.methods.firstOrNull {
            it.name == "unregisterAudioPolicy" && it.parameterTypes.size == 1
        } ?: return
        runCatching { unregister.invoke(am, pol) }
    }
}
