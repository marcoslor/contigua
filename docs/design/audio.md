# Audio phone → Mac — design (muse)

Goal: phone playback (apps streamed to the Mac) plays on the Mac with <150ms
added latency. Phone speaker silent while streaming when feasible.

## Emulator proof (API 36, UID 2000, emulator-5576, 2026-10-14)

Probes ran as shell (`app_process` dex), tone = AudioTrack USAGE_MEDIA 440 Hz
at amplitude 8000 (RMS 5657) in a separate process:

- Plain `AudioRecord(REMOTE_SUBMIX, 48k, stereo)` with no AudioPolicy: opening
  the input routes media to the submix output (`dumpsys audio`: `Devices:
  remote_submix(8000)`; audio_flinger: speaker thread `0 active` tracks while
  the submix thread has the tone). Open-source mirroring tools capture audio the same way.
- Captured RMS 134 at first, then 5656 after raising the music volume: the
  submix device has its own volume index (was 5/15 → −32 dB). An earlier probe
  read that attenuation as "silent" and wrongly concluded a policy was needed;
  the AudioPolicy/AudioMix route then failed on API 36 (`legacy2aidl_AudioMix
  BAD_VALUE`) and is gone.
- The record's attribution must be uid 2000 + `com.android.shell`
  (`AudioRecord.Builder().setContext(ShellContext)`); `app.contigua` at uid
  2000 is rejected by AudioFlinger (`invalid attr`).
- With nothing playing the submix input synthesizes silence ~25% faster than
  realtime; the capture loop drops chunks that run >40 ms ahead of the clock.
- `AudioPlaybackCaptureConfiguration` needs a MediaProjection
  (`MANAGE_MEDIA_PROJECTION`, signature) at shell UID — not used.
- Codecs on device: `c2.android.opus.encoder`, `c2.android.aac.encoder`.

Measured (5 runs, tone write on the phone → buffer played by the Mac,
including the phone mixer, Opus, adb forward, Mac queue and output; clocks
aligned per run, ±30 ms): 79, 81, 95, 103, 126 ms; 0 dropped.

## Approach

Phone (shell service, `app.contigua:…`):

- New `AudioStream`: one device-wide capture, not per-window (submix is a
  single mixer tap). Lifecycle tied to session windows: start on first
  unpaused `window.open`, stop when no unpaused streams remain or session ends.
  `window.pause`/`resume`/`close` drive refcount; no capture when idle (power
  rules).
- Routing: none of our own. Opening the REMOTE_SUBMIX input makes the
  framework route media to the submix output, which silences the speaker —
  the required "silent while streaming". Once routed, STREAM_MUSIC is set to
  max, which only changes the submix device's index (the speaker's is kept);
  user-facing volume is Mac-side gain.
- Capture: `AudioRecord(REMOTE_SUBMIX, 48000, stereo, PCM16)` in a dedicated
  thread, 20ms reads (1920 frames). Feed `MediaCodec audio/opus` encoder
  (48k, stereo, ~64kbps, 20ms frames, `KEY_PRIORITY realtime`).
  Timestamps: `SystemClock.elapsedRealtimeNanos/1000` at read time; first frame
  after start is a "key" (config) equivalent.
- Send: new binary frames on the session (see Protocol). Opus packets are
  small; send each as one frame with session priority below JSON/keyframes but
  above video deltas (audio must not be starved by video backpressure).
  Backpressure: drop oldest audio beyond ~250ms (same budget as video), never
  block JSON/video. No retransmit.

Mac (`Contigua`):

- New `AudioEngine`: `AVAudioEngine` + `AVAudioPlayerNode` with an adaptive
  jitter buffer. The target is the last 10 s p99 arrival lateness + 20 ms
  margin + one 20 ms frame, clamped 60–180 ms (9 × 20 ms; the AAC fallback's 1024-sample
  packets make its queue 192 ms, under the 185 ms A/V trail once the video
  pipeline delay is counted, ITU-R BT.1359); it starts at the 160 ms ceiling and follows the
  measured link. A dry
  queue is one underrun episode, concealed from the last real PCM with a
  decaying crossfade (at most 160 ms); a backlog above the target is drained
  by time-compressing with a crossfade, never by cutting audio; underrun,
  late, concealed and dropped are counted and logged every 5 s. Opus/AAC →
  PCM decode then schedule.
  Opus decode via system `AudioToolbox` (`kAudioFormatOpus` where available);
  if the running SDK lacks a system Opus decoder, fall back to requesting AAC
  from the phone (see negotiation). No new third-party deps (system only).
- Threading (MEDIA-12, #212): every engine and player call runs on one serial
  audio queue, decided by `AudioOutputMachine`; the session queue, the main
  thread, the device-change notification and the played-buffer completions
  only post to it and never wait. AVFAudio's player stop holds the engine's
  lock while it waits for outstanding completions, so a completion that called
  the player (to conceal and schedule) deadlocked the stop, and the main
  thread, which called the player directly, froze the app. A completion now
  reports `rendered` with its episode's generation; a stale one is ignored.
- Session: handle `AUDIO_CONFIG`/`AUDIO_FRAME`, feed engine. Per-device
  volume/mute in menu bar (`MenuBarContent` slider + mute toggle) driving the
  player node gain only — never the phone.
- Clock: `ptsUs` from phone drives A/V ordering evidence; audio clock is the
  player node time, video stays on `AVSampleBufferDisplayLayer` as today.
  No lip-sync target for v1 (apps, not video calls).

Negotiation: Mac sends `audio.start {codec:[opus,aac]}` after `welcome`;
phone answers `AUDIO_CONFIG` with the chosen codec (Opus preferred, AAC if
Opus encoder missing). Mac `audio.stop` on session end. Unknown codecs ignored.

## Audio follows the window

Capture has two modes, chosen by `AudioFollow.plan(windows, uidOf)` from the
session's open windows:

- **Per-app** (the goal): one shell-uid `android.media.audiopolicy` AudioPolicy
  with one loop-back mix filtering the UIDs of the apps shown in open app
  windows (RULE_MATCH_UID per app). Only those apps play on the Mac; every
  other app keeps playing on the phone speaker — nothing is muted.
- **All-audio** (today's REMOTE_SUBMIX path): the speaker goes silent and the
  whole device streams. Reached when (a) a phone-mode window is open (the
  whole-phone mirror means "all audio"), (b) a window cannot be attributed
  (a link whose app Android has not picked yet, a uid lookup failure), or
  (c) the policy registration fails — one log line, then today's path.

Only one path is ever registered: the swap (unregister + register + sink
rebuild, sub-second capture gap, speaker unaffected; keep the Mac jitter
buffer as is) goes through a full stop, and `stop()` always unregisters —
a policy never outlives the session or the server process. The mix output is
not volume-indexed, so only the submix path runs SubmixLevel; per-device
volume stays Mac-side gain either way. Measured (probe): the mix carries the
app's samples 1:1 — a 12000/32767 tone (peak 0.3662) comes out at peak
0.3662 — so the policy path applies no gain. Caveats: apps may opt out of capture
(`setAllowedCapturePolicy`; we register non-privileged), an app without a
mediaPlayback foreground service is background-muted by the platform and
feeds nothing while backgrounded, and shared-UID apps ride one rule (rules
match UIDs, not windows).

## Protocol changes (docs/PROTOCOL.md v1 + audio)

- New types: `0x04 AUDIO_CONFIG`, `0x05 AUDIO_FRAME`, and `0x06 VIDEO_CHUNK`
  (a large access unit as ≤16 KiB fragments so audio can pass between them;
  the Mac reassembles one unit per stream). A phone sends chunks only to a Mac
  whose hello carries `videoChunks:true`.
- `AUDIO_CONFIG` phone→mac, stream 0: `u8 codec` (2 = Opus, 3 = AAC-LC)
  · `u32 sampleRate` · `u8 channels` · `u16 frameMs` · codec-specific setup
  (Opus: empty; AAC: ASC). Sent once after `audio.start`, and after any
  reconfigure. First `AUDIO_FRAME` after it is decodable without prior state.
- `AUDIO_FRAME` phone→mac, stream 0: `u64 ptsUs` · one encoder output packet
  (one Opus frame or one AAC access unit). Max 8MiB rule unchanged.
- JSON: `audio.start {codecs:[..]}` (mac→phone), `audio.stop {}` (mac→phone),
  `audio.state {on:bool, codec:int}` (phone→mac, optional, for UI dot).
- Rules: audio frames never sent with no windows; none while all paused;
  same backpressure/drop semantics as video deltas; unknown types ignored.
- Send order: JSON > keyframes/config > audio > video deltas. The writer
  interleaves audio between a keyframe's `VIDEO_CHUNK` fragments and keeps at
  most 16 KiB unsent in the socket (`TCP_NOTSENT_LOWAT`), so an audio packet
  never waits behind more than one fragment (R4). A partly sent frame keeps
  the head of its stream's lane: its fragments stay contiguous on the wire even
  with two more deltas queued behind it, so the Mac never throws D1 away and
  decodes D2 without its reference (MEDIA-18).

## Alternatives rejected

- AudioPlaybackCapture + MediaProjection: needs `MANAGE_MEDIA_PROJECTION`
  (signature) or user consent dialog; proven blocked at shell UID on API 36.
  Also per-app by design — wrong for device-wide stream, and does not mute
  speaker.
- `cmd audio` / AudioPolicy snoop without submix: no PCM tap, only volumes.
- File/`MediaRecorder` polling: seconds of latency, no streaming.
- AAC primary: higher algorithmic delay (~100ms+ framing) and worse low-rate
  quality than Opus at 64kbps; kept as fallback only for decoders without Opus.
- Per-window audio: submix is device-wide; per-UID routing would need one
  policy per app and still mixes. v1 is device-wide with Mac-side mute.

## Risks

- Emulator rig uses `-no-audio`; audio e2e needs a boot without it (this
  design's rig) or fakephone-only coverage on shared runs.
- Routing scope is the framework's: which usages (notifications, calls) follow
  media to the submix is decided by the device's audio policy; verify on the
  real phone.
- Mac Opus decode via AudioToolbox works on macOS 27 (verified, emulator run);
  AAC fallback stays for decoders without Opus.
- One capture per service: a second Mac session while another streams gets
  no audio until the first stops.
- Speaker silence depends on routing actually muting speaker for routed usages
  on Samsung One UI (AOSP behavior; verify on S25 when available).
- Jitter tuning: the buffer is adaptive (10 s p99 + 40 ms, clamped 60–180 ms).
  On the e2e rig the 100 ms off-channel pattern gives late_p95 ≈ 92 ms with
  zero underruns and drops; one 500 ms stall is one concealed episode. The
  185 ms A/V limit caps the target; a link whose p99 is worse than ~120 ms
  cannot be both unbroken and in sync.
