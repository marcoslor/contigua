package dev.pocketdeck.server

import android.content.Context
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
import java.lang.reflect.Method

/**
 * Audio capture for a session (docs/design/audio.md).
 *
 * Two paths, chosen by [AudioFollow.plan] from the open windows:
 *
 * - **Per-app** (`FollowPlan.PerApp`): one shell-UID `android.media.audiopolicy`
 *   AudioPolicy whose loop-back mix is uid-filtered (RULE_MATCH_UID per window's
 *   app). Only windowed apps stream to the Mac; every other app keeps playing
 *   on the phone speaker. Window open/close swaps the UID set by stopping the
 *   whole capture and building it again (register ~15-65 ms plus sink rebuild,
 *   sub-second gap; the Mac's jitter buffer bridges it, so keep it as is).
 * - **All-audio** (`FollowPlan.AllAudio`, today's path): a REMOTE_SUBMIX
 *   AudioRecord routes media to the submix output, so the phone speaker goes
 *   silent while streaming. Reached for phone-mode windows, on fallback, and
 *   whenever a window cannot be attributed (link pending, uid lookup failure).
 *
 * The two paths never coexist (one policy per client; REMOTE_SUBMIX and a
 * policy mix at once breaks continuity — the swap goes through a full stop).
 * Any policy registration failure falls back to all-audio with one log line,
 * and [stop] always unregisters the policy: nothing registered outlives the
 * session, and the framework drops the policy again if the process dies.
 */
internal class AudioCapture(
    private val ctx: Context,
    private val log: (String) -> Unit,
    /** Package name → app UID for the follow mix rules (shell PackageManager). */
    private val uidOf: (String) -> Int? = { null },
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
        /** AudioDeviceAttributes.ROLE_OUTPUT (hidden). */
        const val ROLE_OUTPUT = 2
        const val MAX_BEHIND_NS = 200_000_000L
        /** Bounded wait for the policy sink to reach RECORDSTATE_RECORDING. */
        const val SINK_RECORDING_WAIT_MS = 1_000L
    }

    @Volatile private var running = false
    @Volatile private var gain = 1f
    @Volatile private var thread: Thread? = null
    @Volatile private var record: AudioRecord? = null
    @Volatile private var codec: MediaCodec? = null
    override val isRunning: Boolean get() = running

    /** The session that last asked for capture (AudioSink identity = the session). */
    @Volatile private var lastSink: AudioSink? = null
    private var lastCodecs: List<Int> = emptyList()
    private var windowsProvider: () -> List<CaptureWindow> = { emptyList() }

    /** Only that owner may move this running capture between plans. */
    @Volatile private var occupiedBy: AudioSink? = null

    /** The plan `record`/`policy` currently implement; null when not running. */
    @Volatile private var activePlan: FollowPlan? = null

    /** The registered AudioPolicy (android.media.audiopolicy.AudioPolicy), if any. */
    private var policy: Any? = null
    private var policyMix: Any? = null

    /**
     * Set when a plan change stopped the capture because the plan went idle;
     * the owner revives it on the next window change (the Mac only re-sends
     * audio.start when its own window set empties, so the phone must restart
     * the capture itself).
     */
    private var wantsRestart = false

    @Synchronized
    override fun start(sink: AudioSink, preferredCodecs: List<Int>, windows: () -> List<CaptureWindow>) {
        if (running) return
        windowsProvider = windows
        lastSink = sink
        lastCodecs = preferredCodecs
        wantsRestart = false
        startLocked(sink, preferredCodecs)
    }

    @Synchronized
    override fun stop() {
        if (!running && thread == null && policy == null) return
        wantsRestart = false
        stopLocked()
        log("audio: stopped")
    }

    @Synchronized
    override fun onWindowsChanged(owner: AudioSink?) {
        if (running && occupiedBy !== owner) return
        if (!running && lastSink !== owner) return
        val next = AudioFollow.plan(windowsProvider(), uidOf)
        if (running) {
            if (next == activePlan) return
            log("audio: plan $activePlan -> $next")
            stopLocked()
            wantsRestart = next is FollowPlan.Idle
        }
        if (next !is FollowPlan.Idle) {
            val sink = lastSink ?: return
            startLocked(sink, lastCodecs)
        }
    }

    /** Builds record + encoder for the current plan; runs in the class monitor. */
    private fun startLocked(sink: AudioSink, preferredCodecs: List<Int>) {
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
        val requestedPlan = AudioFollow.plan(windowsProvider(), uidOf)
        if (requestedPlan is FollowPlan.Idle) {
            log("audio: nothing to capture (no followable window)")
            return
        }
        val enc = buildEncoder(mime, codecId) ?: return

        var rec: AudioRecord? = null
        var effective = requestedPlan
        var why = ""
        if (requestedPlan is FollowPlan.PerApp) {
            rec = openPolicyRecord(requestedPlan.uids)
            if (rec == null) {
                // One log line inside openPolicyRecord; degrade to today's path.
                effective = FollowPlan.AllAudio
            }
        }
        if (effective is FollowPlan.AllAudio) {
            why = "remote submix"
            levelSubmix()
            rec = openSubmixRecord() ?: run {
                runCatching { enc.release() }
                return
            }
        }
        running = true
        occupiedBy = sink
        record = rec
        codec = enc
        activePlan = effective
        // The policy mix streams at full scale (verified in K4: the mix output
        // is not volume-indexed). Only the submix path needs SubmixLevel.
        gain = if (effective is FollowPlan.AllAudio) submixGain else 1f

        sink.onAudioConfig(codecId, SAMPLE_RATE, CHANNELS, FRAME_MS, ByteArray(0))
        log("audio: capturing codec=$codecId ($mime) plan=${describe(effective, why)}")
        thread = Thread({ loop(sink, codecId, enc) }, "pocketdeck-audio").also { it.start() }
        runCatching { rec?.startRecording() }
            .onFailure {
                log("audio: startRecording failed: ${it.message}")
                stop()
            }
    }

    private fun describe(plan: FollowPlan, why: String) = when (plan) {
        is FollowPlan.PerApp -> "per-app uids=${plan.uids.joinToString("+")}"
        FollowPlan.AllAudio -> "all-audio ($why)"
        FollowPlan.Idle -> "idle"
    }

    @Synchronized
    private fun stopLocked() {
        if (!running && thread == null && policy == null) return
        running = false
        runCatching { record?.stop() }
        runCatching { Thread.sleep(20) }
        runCatching { codec?.stop() }
        runCatching { codec?.release() }
        runCatching { record?.release() }
        val pol = policy
        codec = null
        record = null
        policy = null
        policyMix = null
        occupiedBy = null
        activePlan = null
        if (pol != null) {
            try {
                unregisterPolicy(pol)
            } catch (t: Throwable) {
                log("audio: unregister failed: ${t.message}")
            }
        }
        val t = thread
        thread = null
        if (t != null && t !== Thread.currentThread()) runCatching { t.join(1000) }
    }

    private fun loop(sink: AudioSink, codecId: Int, enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        val chunk = ByteArray(CHUNK_BYTES)
        var sentAacSetup = false
        var clockBaseNs = 0L
        var producedNs = 0L
        while (running) {
            val inRec = record
            if (inRec == null) {
                Thread.sleep(20)
                continue
            }
            val n = try {
                inRec.read(chunk, 0, chunk.size)
            } catch (_: Throwable) {
                break
            }
            if (n <= 0) continue
            SubmixLevel.applyGain(chunk, n, gain)
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
     * Brings the capture to full scale without ever setting the music stream
     * volume (see [SubmixLevel]). Sets the submix device's own index to max
     * via the hidden AudioDeviceVolumeManager.setDeviceVolume (allowed for
     * shell on API 34-36), then reads that device's index back. Runs before
     * recording starts: AudioService skips setDeviceVolume for the device
     * music currently plays on, so it can only change the idle submix device,
     * never the speaker. If the index is not at max afterwards, the PCM is
     * boosted by the submix attenuation instead.
     */
    private fun levelSubmix() {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val index = runCatching {
            val volume = DeviceVolume(ctx)
            volume.set(max)
            volume.get()
        }.onFailure { log("audio: submix device volume: ${it.cause?.message ?: it.message}") }.getOrNull()
        val plan = SubmixLevel.plan(
            deviceVolumeSet = index == max,
            submixDb = index?.let {
                am.getStreamVolumeDb(AudioManager.STREAM_MUSIC, it, AudioDeviceInfo.TYPE_REMOTE_SUBMIX)
            },
        )
        submixGain = if (plan is SubmixLevel.Plan.SoftwareGain) plan.gain else 1f
        log("audio: submix index=$index level $plan")
    }

    /** The gain decided by the last [levelSubmix] (submix attenuation undo). */
    @Volatile private var submixGain = 1f

    /** REMOTE_SUBMIX record of the all-audio path; null when it cannot be opened. */
    private fun openSubmixRecord(): AudioRecord? {
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            log("audio: bad min buffer $minBuf")
            return null
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
            return null
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            log("audio: record not initialized")
            runCatching { rec.release() }
            return null
        }
        return rec
    }

    private fun buildEncoder(mime: String, codecId: Int): MediaCodec? {
        val enc = try {
            MediaCodec.createEncoderByType(mime)
        } catch (t: Throwable) {
            log("audio: no $mime encoder: ${t.message}")
            return null
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
            return null
        }
        return enc
    }

    /**
     * Registers the uid-filtered loop-back mix (one rule per window app; the
     * exact construction probed in .agent/perapp/findings.md) and returns its
     * recording sink, or null when the framework rejects it — the caller then
     * falls back to all-audio. Storing `policy` before any later failure lets
     * that failure path unregister it, so nothing is left registered.
     */
    private fun openPolicyRecord(uids: List<Int>): AudioRecord? {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return runCatching {
            val rb = PolicyAudio.mixingRuleBuilder.getConstructor().newInstance()
            PolicyAudio.setTargetMixRole.invoke(rb, PolicyAudio.rolePlayers)
            for (uid in uids) {
                PolicyAudio.addMixRule.invoke(rb, PolicyAudio.ruleMatchUid, uid)
            }
            // Capture stays non-privileged: the windowed apps' own capture
            // opt-out (setAllowedCapturePolicy) is honored that way.
            runCatching { PolicyAudio.allowPrivilegedPlaybackCapture.invoke(rb, false) }
            val rule = PolicyAudio.ruleBuild.invoke(rb)

            val fmt = AudioFormat.Builder()
                .setSampleRate(SAMPLE_RATE)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build()
            val mixBuilder = PolicyAudio.mixBuilder
                .getConstructor(PolicyAudio.mixingRule)
                .newInstance(rule)
            PolicyAudio.mixSetFormat.invoke(mixBuilder, fmt)
            PolicyAudio.mixSetRouteFlags.invoke(mixBuilder, PolicyAudio.routeLoopBack)
            val mix = PolicyAudio.mixBuild.invoke(mixBuilder)

            val pb = PolicyAudio.policyBuilder.getConstructor(Context::class.java).newInstance(ctx)
            PolicyAudio.policyAddMix.invoke(pb, mix)
            val pol = PolicyAudio.policyBuild.invoke(pb)

            val rc = PolicyAudio.amRegisterPolicy.invoke(am, pol) as Int
            if (rc != 0) {
                log("audio: registerAudioPolicy(uids=${uids.joinToString("+")}) rc=$rc")
                return@runCatching null
            }
            policy = pol
            policyMix = mix
            val sink = createPolicySink(pol, mix) ?: return@runCatching null
            // startRecording needs a beat (measured ~130 ms to RECORDING).
            sink.startRecording()
            val deadline = System.currentTimeMillis() + SINK_RECORDING_WAIT_MS
            while (sink.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                Thread.sleep(20)
                if (System.currentTimeMillis() >= deadline) return@runCatching null
            }
            sink
        }.onFailure {
            log("audio: policy mix failed: ${it.javaClass.simpleName}: ${it.message}")
        }.getOrNull().also { sink ->
            if (sink == null) releaseHeldPolicy()
        }
    }

    /**
     * The mix's recording record. The framework's createAudioRecordSink builds
     * it with the process attribution (our package, rejected at uid 2000), so
     * this rebuilds the identical record (same REMOTE_SUBMIX capture preset and
     * mix-address tags; AudioPolicy.createAudioRecordSink's own construction)
     * with the shell attribution that AudioFlinger accepts.
     */
    private fun createPolicySink(pol: Any, mix: Any): AudioRecord? {
        val framework = runCatching {
            PolicyAudio.policyCreateSink.invoke(pol, mix) as? AudioRecord
        }.getOrNull()
        if (framework != null && framework.state == AudioRecord.STATE_INITIALIZED) {
            return framework
        }
        runCatching { framework?.release() }
        return runCatching {
            val registration = PolicyAudio.mixGetRegistration.invoke(mix) as? String
            if (registration.isNullOrEmpty()) {
                log("audio: mix has no registration id; cannot tailor the sink")
                return@runCatching null
            }
            // AudioPolicy.createAudioRecordSink's exact AudioAttributes:
            // internal capture preset REMOTE_SUBMIX, the mix's registered
            // address, and the fixed-volume tag.
            val ab = PolicyAudio.attributesBuilder.getConstructor().newInstance()
            PolicyAudio.attrsSetInternalCapturePreset.invoke(ab, MediaRecorder.AudioSource.REMOTE_SUBMIX)
            PolicyAudio.attrsAddTag.invoke(ab, "addr=$registration")
            PolicyAudio.attrsAddTag.invoke(ab, PolicyAudio.submixFixedVolume)
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf <= 0) {
                log("audio: policy sink: bad min buffer $minBuf")
                return@runCatching null
            }
            // The hidden Builder.setAudioAttributes carries the mix's address
            // tags; setContext supplies the shell attribution AudioFlinger
            // accepts (the framework's own sink uses the process attribution
            // and is rejected at uid 2000 with a package).
            val rb = AudioRecord.Builder()
                .apply { if (Build.VERSION.SDK_INT >= 31) setContext(ctx) }
            PolicyAudio.recordSetAttributes.invoke(rb, PolicyAudio.attrsBuild.invoke(ab))
            val rec = rb
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(
                            PolicyAudio.inFromOutChannelMask.invoke(
                                null, PolicyAudio.channelOutStereo,
                            ) as Int
                        )
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBuf, CHUNK_BYTES * 4))
                .build()
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                log("audio: policy sink record not initialized (${rec.state})")
                runCatching { rec.release() }
                return@runCatching null
            }
            log("audio: policy sink on the shell attribution (framework sink rejected the process attribution)")
            rec
        }.getOrNull()
    }

    private fun releaseHeldPolicy() {
        val pol = policy ?: return
        policy = null
        policyMix = null
        try {
            unregisterPolicy(pol)
        } catch (t: Throwable) {
            log("audio: fallback unregister failed: ${t.message}")
        }
    }

    private fun unregisterPolicy(pol: Any) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val rc = PolicyAudio.amUnregisterPolicy.invoke(am, pol) as? Int
        if (rc != null && rc != 0) log("audio: unregisterAudioPolicy rc=$rc")
        policyMix = null
    }

    /** STREAM_MUSIC index of the remote-submix output device only (hidden APIs). */
    private class DeviceVolume(ctx: Context) {
        private val infoClass = Class.forName("android.media.VolumeInfo")
        private val deviceClass = Class.forName("android.media.AudioDeviceAttributes")
        private val managerClass = Class.forName("android.media.AudioDeviceVolumeManager")
        private val manager = managerClass.getConstructor(Context::class.java).newInstance(ctx)
        private val device = deviceClass
            .getConstructor(Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java)
            .newInstance(ROLE_OUTPUT, AudioDeviceInfo.TYPE_REMOTE_SUBMIX, "0")

        private fun info(index: Int?): Any {
            val builder = Class.forName("android.media.VolumeInfo\$Builder")
                .getConstructor(Int::class.javaPrimitiveType).newInstance(AudioManager.STREAM_MUSIC)
            if (index != null) {
                builder.javaClass.getMethod("setVolumeIndex", Int::class.javaPrimitiveType).invoke(builder, index)
            }
            return builder.javaClass.getMethod("build").invoke(builder)
        }

        fun set(index: Int) {
            managerClass.getMethod("setDeviceVolume", infoClass, deviceClass).invoke(manager, info(index), device)
        }

        fun get(): Int {
            val got = managerClass.getMethod("getDeviceVolume", infoClass, deviceClass).invoke(manager, info(null), device)
            return infoClass.getMethod("getVolumeIndex").invoke(got) as Int
        }
    }
}

/**
 * Reflection into the hidden `android.media.audiopolicy` classes. On this API
 * level `android.media.AudioMix` is only a parcel stub and AudioMixingRule does
 * not exist there, so the policy path always names this package (probed: a
 * mix from the stub class fails legacy2aidl conversion with BAD_VALUE).
 */
private object PolicyAudio {
    val mixingRule = Class.forName("android.media.audiopolicy.AudioMixingRule")
    val mixingRuleBuilder = Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
    val mix = Class.forName("android.media.audiopolicy.AudioMix")
    val mixBuilder = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
    val policy = Class.forName("android.media.audiopolicy.AudioPolicy")
    val policyBuilder = Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")

    val rolePlayers: Int = staticInt(mixingRule, "MIX_ROLE_PLAYERS")
    val ruleMatchUid: Int = staticInt(mixingRule, "RULE_MATCH_UID")
    val routeLoopBack: Int = staticInt(mix, "ROUTE_FLAG_LOOP_BACK")

    val setTargetMixRole = declared(mixingRuleBuilder, "setTargetMixRole", Int::class.javaPrimitiveType!!)
    val addMixRule = declared(mixingRuleBuilder, "addMixRule", Int::class.javaPrimitiveType!!, Any::class.java)
    val allowPrivilegedPlaybackCapture =
        declared(mixingRuleBuilder, "allowPrivilegedPlaybackCapture", Boolean::class.javaPrimitiveType!!)
    val ruleBuild = declared(mixingRuleBuilder, "build")

    val mixSetFormat = declared(mixBuilder, "setFormat", AudioFormat::class.java)
    val mixSetRouteFlags = declared(mixBuilder, "setRouteFlags", Int::class.javaPrimitiveType!!)
    val mixBuild = declared(mixBuilder, "build")

    val policyAddMix = declared(policyBuilder, "addMix", mix)
    val policyBuild = declared(policyBuilder, "build")

    val amRegisterPolicy = declared(AudioManager::class.java, "registerAudioPolicy", policy)
    val amUnregisterPolicy = declared(AudioManager::class.java, "unregisterAudioPolicy", policy)
    val policyCreateSink = declared(policy, "createAudioRecordSink", mix)

    /** The mix address the framework Environment's own sink tags its record with. */
    val mixGetRegistration = declared(mix, "getRegistration")

    // The AudioPolicy.createAudioRecordSink pieces that are not public API.
    val attributesBuilder = Class.forName("android.media.AudioAttributes\$Builder")
    val attrsSetInternalCapturePreset =
        declared(attributesBuilder, "setInternalCapturePreset", Int::class.javaPrimitiveType!!)
    val attrsAddTag = declared(attributesBuilder, "addTag", String::class.java)
    val attrsBuild = declared(attributesBuilder, "build")
    val submixFixedVolume: String = run {
        for (f in android.media.AudioRecord::class.java.declaredFields) {
            if (f.name == "SUBMIX_FIXED_VOLUME") {
                f.isAccessible = true
                return@run f.get(null) as String
            }
        }
        "submix_fixed_volume"
    }
    val channelOutStereo: Int = AudioFormat.CHANNEL_OUT_STEREO
    val inFromOutChannelMask = declared(
        AudioFormat::class.java, "inChannelMaskFromOutChannelMask", Int::class.javaPrimitiveType!!,
    )

    // Hidden Builder.setAudioAttributes(@SystemApi): the sink's AudioAttributes
    // are not expressible through the public API.
    val recordBuilder = Class.forName("android.media.AudioRecord\$Builder")
    val recordSetAttributes = declared(recordBuilder, "setAudioAttributes", android.media.AudioAttributes::class.java)

    private fun staticInt(cls: Class<*>, name: String): Int {
        for (f in cls.declaredFields) {
            if (f.name != name) continue
            f.isAccessible = true
            return f.getInt(null)
        }
        throw NoSuchFieldException("$cls.$name")
    }

    /** First declared [name] matching every argument type, walking superclasses. */
    private fun declared(cls: Class<*>, name: String, vararg types: Class<*>): Method {
        var c: Class<*>? = cls
        while (c != null) {
            for (m in c.declaredMethods) {
                if (m.name != name) continue
                val pt = m.parameterTypes
                if (pt.size != types.size) continue
                var matches = true
                for (i in types.indices) {
                    if (pt[i] != types[i]) {
                        matches = false
                        break
                    }
                }
                if (!matches) continue
                m.isAccessible = true
                return m
            }
            c = c.superclass
        }
        throw NoSuchMethodException("$cls.$name")
    }
}
