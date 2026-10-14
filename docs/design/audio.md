# Audio phone → Mac — design (muse)

Goal: phone playback (apps streamed to the Mac) plays on the Mac with <150ms
added latency. Phone speaker silent while streaming when feasible.

## Emulator proof (API 36, UID 2000, emulator-5564, 2026-10-14)

All probes ran as shell (`adb -s emulator-5564 shell`, `app_process` dex):

- `AudioRecord(REMOTE_SUBMIX, 48k, stereo)` → `STATE_INITIALIZED`, `startRecording`
  ok, `read` returns bytes. Silence when nothing plays (expected).
- Tone test (AudioTrack 440Hz sine + simultaneous REMOTE_SUBMIX record, no
  policy): 192000 bytes, rms 34, 4088/96000 nonzero → effectively silent.
  Conclusion: a routing policy is required; raw submix does not mirror speaker.
- `AudioPlaybackCaptureConfiguration.Builder()` on API 36 takes a mandatory
  `MediaProjection` arg (compile error without one). No-projection capture is
  impossible on this API level.
- `IMediaProjectionManager.createProjection(2000, com.android.shell, type, …)`
  fails for all types 0–2 with `Requires MANAGE_MEDIA_PROJECTION`
  (protectionLevel `signature`; shell lacks it). So AudioPlaybackCapture is
  unreachable from the shell service without user consent — rejected.
- Shell grants (verified): `CAPTURE_AUDIO_OUTPUT`, `MANAGE_AUDIO_POLICY`,
  `MODIFY_AUDIO_ROUTING` all `granted=true`; priv-app flags include
  `ALLOW_AUDIO_PLAYBACK_CAPTURE`, `PRIVILEGED`. `REMOTE_SUBMIX` input device
  exists in `dumpsys media.audio_policy`.
- Codecs on device: `c2.android.opus.encoder (audio/opus)`,
  `c2.android.aac.encoder`, `OMX.google.aac.encoder`. Opus encode on-device OK.

Decision: **REMOTE_SUBMIX + AudioPolicy routing + Opus**. This is the only
route proven reachable at shell UID without user interaction.

## Approach

Phone (shell service, `dev.pocketdeck:…`):

- New `AudioStream`: one device-wide capture, not per-window (submix is a
  single mixer tap). Lifecycle tied to session windows: start on first
  unpaused `window.open`, stop when no unpaused streams remain or session ends.
  `window.pause`/`resume`/`close` drive refcount; no capture when idle (power
  rules).
- Routing: `AudioPolicy` with one `AudioMix` (`ROUTE_FLAG_RENDER`,
  device `TYPE_REMOTE_SUBMIX`, 48k stereo PCM16) + `AudioMixingRule`
  matching `USAGE_MEDIA`, `USAGE_GAME`, `USAGE_UNKNOWN` (players only).
  Register on start, unregister on stop. Routing to submix silences the phone
  speaker for routed usages — the required "silent while streaming".
  Do NOT touch stream volumes; Mac-side gain only.
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

Mac (`PocketDeck`):

- New `AudioEngine`: `AVAudioEngine` + `AVAudioPlayerNode` with a jitter
  buffer (target 60ms, max 120ms). Opus → PCM decode then schedule.
  Opus decode via system `AudioToolbox` (`kAudioFormatOpus` where available);
  if the running SDK lacks a system Opus decoder, fall back to requesting AAC
  from the phone (see negotiation). No new third-party deps (system only).
- Session: handle `AUDIO_CONFIG`/`AUDIO_FRAME`, feed engine. Per-device
  volume/mute in menu bar (`MenuBarContent` slider + mute toggle) driving the
  player node gain only — never the phone.
- Clock: `ptsUs` from phone drives A/V ordering evidence; audio clock is the
  player node time, video stays on `AVSampleBufferDisplayLayer` as today.
  No lip-sync target for v1 (apps, not video calls).

Negotiation: Mac sends `audio.start {codec:[opus,aac]}` after `welcome`;
phone answers `AUDIO_CONFIG` with the chosen codec (Opus preferred, AAC if
Opus encoder missing). Mac `audio.stop` on session end. Unknown codecs ignored.

## Protocol changes (docs/PROTOCOL.md v1 + audio)

- New types: `0x04 AUDIO_CONFIG`, `0x05 AUDIO_FRAME` (next free after video).
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
- `AudioPolicy` routing scope: must match only media/game usages or calls and
  notifications leak into the Mac; mixing rule needs device verification.
- Mac Opus decode via AudioToolbox must be verified on macOS 26 SDK; fallback
  to AAC covers failure but adds latency.
- Speaker silence depends on routing actually muting speaker for routed usages
  on Samsung One UI (AOSP behavior; verify on S25 when available).
- Jitter tuning: 60ms target keeps budget (<20 opus + <30 net + 60 jitter +
  ~20 render ≈ 130ms) but lossy LAN may need adaptive growth; counters first.
