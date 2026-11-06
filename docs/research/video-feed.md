# Video feed: why scrolling stutters and gets blocky, and what to try (ISS-40, ISS-42)

Status, 2026-11-05: **research, plus the strategy switches as bench-only experiment knobs (see "Strategy switches").** The person, 2026-11-04, after app windows went 1:1 (ISS-39): scrolling feels smoother, but "the video sometimes drops frames, feeling janky", and while the content moves the picture is visibly more pixelated. They asked for the strategies other streaming products use to be logged and tested, with a performance/quality preset in mind, though not exposed in the app yet.

Measured on the person's phone (SM-S936B, `c2.qti.avc.encoder`, v140) and Mac (Wi-Fi 6, 5 GHz), 2026-11-04 and 11-05.

## What today's pipeline does

- **Phone:**
  - H.264, VBR, 60 fps, no B-frames, `KEY_PRIORITY` 0 (realtime), `KEY_LATENCY` 1, a keyframe every 10 s, `KEY_REPEAT_PREVIOUS_FRAME_AFTER` 500 ms.
  - Bitrate is about 0.12 bit per pixel per second at 60 fps, capped at **8 Mbps** (`WindowStream.bitrateFor`).
  - At that cap, a 1232×2410 window would want about 21 Mbps.
- **Transport:** one TLS-over-TCP connection. Frames go through a send queue (`SendQueue`), allowing about 250 ms of queued video per stream, counted both by bytes and by time.
- **Overflow:** the queue drops every queued delta, drops more until the next keyframe, and asks the encoder for one (`onDeltaDrop`). The bitrate falls 25 % (`onBackpressure`). It recovers 10 % every 5 s without a drop.
- **Mac:** `AVSampleBufferDisplayLayer`, each sample marked `DisplayImmediately`. A frame shows as soon as it's decoded, with no pacing and no buffer.

## What the person's session shows

An image-heavy shopping app in an app window, 23:55:04–23:56:23 (78 s), with resizes and a density change:

- 5 overflow episodes. Two of them came in pairs 110 ms and 290 ms apart: the keyframe asked for after the first drop overflowed the queue again.
- Each one stops the picture until the keyframe arrives. That is the "dropped frames" feel.
- The bitrate went 8 → 6 → 4.5 Mbps and needed about 15 s to climb back to 6. That is the extra blockiness after a stutter.
- Every resize builds a new encoder at the full target, so the cycle starts over.

So both complaints come from one loop:

1. the link stalls;
2. the queue passes 250 ms;
3. all deltas are dropped and a large keyframe is asked for;
4. the bitrate is cut and stays low.

## The link stalls, and the radio is not the cause

Phone Wi-Fi: 11ax, 5 GHz, −25 dBm, 2161 Mbps link rate. Mac Wi-Fi: 11ax on the same channel, 80 MHz, with AWDL (`awdl0`, used by AirDrop, Universal Control and Continuity) active.

Pings from the Mac every 50 ms, 3 × 15 s per arm, to the router and to the phone at the same time (a stall seen on both at once is the Mac's side; one only on the phone is the phone's side):

| Arm | Target | p50 | p95 | p99 | max | > 50 ms | > 100 ms |
| --- | --- | --- | --- | --- | --- | --- | --- |
| normal | phone | 6.9 | 54.8 | 63.4 | 100 | 7.0 % | 0.0 % |
| normal | router | 4.1 | 5.6 | 9.7 | 94 | 0.4 % | 0.0 % |
| phone `cmd wifi force-low-latency-mode enabled` | phone | 6.7 | 112 | 512 | 708 | 7.1 % | 5.1 % |
| same | router | 4.2 | 76 | 551 | 662 | 5.6 % | 3.9 % |

- **The phone's side:** about 7 % of round trips take 50–100 ms whatever the mode. Android's forced low-latency Wi-Fi mode doesn't change this. This is at idle; the stream's own traffic may keep the radio awake, so the stream's numbers decide.
- **The Mac's side:** now and then the Mac's radio goes quiet for 0.3–0.7 s; the router sees the same stall. AWDL's off-channel time is the usual cause on Macs. Game-streaming guides for macOS name it as the cause of periodic stutter.
- **Single sample:** one 20 ms ping train showed a 240 ms stall released as a staircase (235, 205, 175 … 8 ms). Our 250 ms queue limit is about the length of one such stall.

The 0.3–0.7 s stalls can't be fixed in the app; they can only be survived without a keyframe storm. That is what the strategies below are for.

## What game and desktop streaming do

Game streaming (Moonlight/Sunshine, Parsec, Steam Remote Play, GeForce NOW) and remote desktops (Chrome Remote Desktop, RDP, RustDesk) settle on the same few ideas:

1. **Never throw away frames that later frames depend on.**
   - *What they do:* they lower the bitrate or skip a frame at the source. Moonlight and NVIDIA recover from a lost frame by invalidating a reference frame, or by an intra refresh band that sweeps down the picture over a few frames, never by a full keyframe.
   - *Why:* a keyframe on a congested link is the most expensive thing you can send.
2. **Keep the send queue tiny and adapt the encoder to the link** (GCC in WebRTC, SCReAM, L4S-style schemes; see the sources).
   - *What they do:* estimate the available rate from delivery timing (queueing delay growth), not from a queue overflowing, and run the encoder somewhat below the estimate.
   - *Why:* when the queue grows, the bitrate drops within a frame or two.
3. **Constant bitrate with a one-frame VBV buffer for low latency** (NVENC "ultra-low-latency" with CBR, as in Sunshine's defaults).
   - *Why:* every frame's size stays near the average, so a scroll doesn't produce a burst that sits in the queue.
   - *What they do with spare budget:* the VBV can be raised a little so a low-motion frame can be better.
4. **A preset that picks what to give up.** WebRTC names this `degradationPreference`:
   - **maintain-resolution** (Chrome's default for screen sharing, because scaling makes text unreadable): under pressure, frame rate goes down and pixels stay sharp. This is the "quality" preset.
   - **maintain-framerate:** resolution or quality goes down and 60 fps stays. This is the "performance" preset; game streaming defaults to it.
   - Moonlight's client has the same split for display: "prefer lowest latency" (show on arrival) versus "prefer smoothest video" (a frame of buffer, shown on the display's refresh).
5. **Refine still frames.** When motion stops, send a high-quality refresh of the same picture: Chrome Remote Desktop's "top-off", RemoteFX's progressive passes, RustDesk's re-encode of static frames.
   - The refresh must yield to new motion (RustDesk's PR notes that a refinement frame can delay the next real frame).
   - Today we do the opposite: `KEY_REPEAT_PREVIOUS_FRAME_AFTER` repeats the blocky last motion frame. This is ISS-40 (d).
6. **More bits on a LAN.** Defaults are far above 8 Mbps:
   - Moonlight's client defaults are about 20 Mbps at 1080p60, and it recommends 40–80 Mbps for 1440p/4K;
   - scrcpy's default is 8 Mbps, but over USB.
   - HEVC gives the same quality for about 30–50 % fewer bits, and the Mac decodes it in hardware (ISS-40 c).
7. **Mark the traffic as video on the air.** WebRTC sets DSCP AF41 on video packets. Wi-Fi maps it to the WMM video access category, which wins contention against best-effort traffic. On macOS, a socket's service type does the same.
8. **Don't send pixels the screen can't show.** On a scaled display ("looks like 3008×1692" on a 3840×2160 panel), a window's backing store is 6016/3840 = 1.57× the panel on each axis. That is 2.45× the panel's pixels. Asking the phone for backing pixels spends 2.45× the bits for detail the panel throws away.

## What the person's encoder can do

`/vendor/etc/media_codecs*.xml` on the phone. `c2.qti.avc.encoder` and `c2.qti.hevc.encoder` both have:

- bitrate modes VBR and CBR;
- `intra-refresh`;
- `encoding-statistics`: per-frame average QP in each output buffer's format (`KEY_VIDEO_QP_AVERAGE`), a direct number for "how blocky was this frame";
- `video-minimum-quality`: a VBR quality floor;
- sizes up to 8192×8192, bitrate up to 220 Mbps (AVC) and 160 Mbps (HEVC);
- `region-of-interest` (checked 2026-11-05): per-rectangle QP offsets through `MediaCodec.PARAMETER_KEY_QP_OFFSET_RECTS` (Android 15).

There is no AV1 encoder, so AV1's screen-content tools are out of reach. Both encoders are 4:2:0 only.

`MediaCodec.PARAMETER_KEY_SUSPEND` drops Surface input at the encoder's input without breaking the reference chain. It can skip frames at the source while the queue is full.

## The strategies to test

Each one is a switch whose default is today's behaviour: a `debug.pocketdeck.stream.*` property on the phone, a `defaults` key on the Mac.

| Id | Side | Strategy | What it should change |
| --- | --- | --- | --- |
| Q1 | phone | Overflow skips frames at the source (`PARAMETER_KEY_SUSPEND` while the queue holds more than a frame budget), and the queue never drops encoded deltas. The encoder takes the queue's latest state (not an edge), an empty backlog counts as drained, and a suspend resumes within 1 s whatever the backlog. | no freeze-until-keyframe; lower fps for the length of a stall, and never a frozen picture |
| Q2 | phone | Queue budget 250 ms → 100 ms / 50 ms, with Q1. | lower latency; what does it cost in fps |
| R1 | phone | CBR instead of VBR. | flatter frame sizes, fewer bursts |
| R2 | phone | Bitrate cap 8 → 16 / 25 / 40 Mbps, plus the per-pixel target. | less blockiness in motion, if the link holds it |
| R3 | phone | Delay-based rate control: the bitrate follows the measured delivery rate and queue delay instead of −25 % on an overflow. | adapts before a stall, recovers in seconds, not 15 s |
| R4 | phone | Intra refresh instead of the 10 s keyframe (`KEY_INTRA_REFRESH_PERIOD`). | no periodic keyframe spike; it only counts once the frame a drop resumes on is proven an IDR (`key_not_idr = 0` at both ends; the counters are NAL types, never bytes) |
| C1 | phone | HEVC instead of H.264 (the Mac says it can decode it). | the same quality at fewer bits |
| T1 | phone | Still refinement: about 300 ms after motion stops, one high-quality frame (a sync frame at a raised bitrate or a lower QP cap), dropped if motion resumes. | still text is sharp again within a second |
| N1 | both | Traffic marked as video (`IP_TOS` AF41 on the phone's socket; `NET_SERVICE_TYPE_VI` on the Mac's). | fewer air stalls on a busy network |
| M1 | Mac | Paced display: a one-frame buffer shown on the display's refresh instead of `DisplayImmediately`. | even frame spacing after a burst, at about +1 frame of latency |
| M2 | Mac | Ask for at most the panel's pixels on a scaled display (the window's pixels × panel width / backing width). | 2.45× fewer pixels on the person's main display for the same bits |
| W1 | phone | Probe, no product change: Wi-Fi power save and `cmd wifi force-low-latency-mode` measured with the stream's own traffic. | is the phone's 50 ms tail real under load |

### What the leading products do that the list above doesn't (2026-11-05)

The list above is the shared core of game and desktop streaming. Four more ideas from the same products were missing. The person left the order to the reviewer.

| Id | Side | Strategy | What it should change |
| --- | --- | --- | --- |
| X0 | both | Probe, no product change: the connection's resent and out-of-order packets in each 5 s line — the Mac's `TCP_CONNECTION_INFO` on the stream socket (`tcp_srtt`, `tcp_rttvar`, and `tcp_ooo_kb`, the bytes that arrived after a hole) and the phone's system-wide `/proc/net/snmp` `RetransSegs` plus `/proc/net/netstat` `TCPTimeouts` and `TCPLostRetransmit` (`ph_retrans`, `ph_rto`, `ph_lost`) — lined up with the hitches by the bench's per-arm block. | tells whether TCP's head-of-line blocking is behind the 50–200 ms hitches |
| X1 | both | Video over UDP with forward error correction and a resend of only what still matters; control stays on TLS over TCP. WebRTC's RTP is the candidate, since ISS-41's web client needs it anyway. | one lost packet costs a repair, not a stall of every frame behind it; the video backlog no longer delays input and clipboard messages |
| X2 | phone | Recovery by reference: after a loss, the encoder predicts from an older frame the Mac has confirmed (reference-frame invalidation, long-term references), not from a keyframe. | no keyframe after a loss; matters only with X1, because TCP loses nothing once Q1 stops the drops |
| T2 | phone | Region-of-interest QP offsets: a lower QP where the picture changed or holds text, a higher one on flat areas. | sharper text in motion for the same bits |
| T3 | Mac | Low-latency super-resolution (`VTLowLatencySuperResolutionScaler`, VideoToolbox, macOS 26): ask the phone for fewer pixels and upscale on the Mac. | fewer bits per frame; it must neither smear nor invent text, which the arm checks first |
| T4 | phone | Full chroma (4:4:4) carried in two 4:2:0 streams, luma and chroma, as RDP's AVC444 mode does. | clean coloured text edges, at about twice the encode cost; later |
| M3 | Mac | An adaptive jitter buffer: the display delay follows the measured arrival jitter, as WebRTC's does, instead of M1's fixed one frame (16 ms, against hitches of 50–200 ms). | hides the hitches at a measured latency cost; a natural preset knob |

Left out on purpose:
- **L4S:** it needs a router that marks ECN, which most home routers don't.
- **AWDL off:** it is an admin setting that breaks AirDrop and Universal Control. The 0.3–0.7 s stalls it causes are the person's choice to remove, not the app's.

The order after round 2:
1. X0 rides along in round 2.
2. If the resends line up with the hitches, X1 comes before R3. Over UDP, R3's delay-based control comes with the transport's own estimator.
3. C1, then T2 and T3, as arms.
4. M3 replaces M1.
5. T4 last.

## How each run is measured

The stats work (ISS-40's measurement, `.agent/stats/brief.md`) logs a line per
window every 5 s, and **one complete line when the window closes**:

- **Smoothness:**
  - frames shown per second on the Mac;
  - frame interval p95 and p99;
  - freezes: gaps over 100 ms, counted, and their total time (kept for
    continuity; the bench table now leads with jank below);
  - hitches: frames shown more than 50 ms after their capture step, counted and
    summed, with late p99; the drop episodes and their pts gaps, and Q1's
    suspends, complete the picture (see "Measuring jank").
- **Latency:** capture-to-shown p50 and p95, from the frame's timestamp and a clock offset from `ping`/`pong`.
- **Blockiness:** the phone's per-frame average QP p50 and p95 during motion (the encoder reports it), and kilobits per second.
- **Recovery:** the time from the end of a scroll until the still picture's PSNR against the phone's lossless capture is within 1 dB of its final value (`crisp-metric.py`).
- **Pressure:** queue drops, skipped frames, keyframes, the target bitrate.
- **Resends (X0):** on the Mac's side of the one TLS-over-TCP connection,
  `tcp_srtt` and `tcp_rttvar` (the socket's smoothed round trip and its
  variance, ms) and `tcp_ooo_kb`: the `tcpi_rxoutoforderbytes` delta since the
  previous line, in KB. Out-of-order bytes are data that arrived after a
  missing segment; TCP holds it until the resend fills the hole, so it is the
  receiver's trace of head-of-line blocking. The totals line has the same
  over the window's life (`tcp_ooo_kb`) and its worst round trip
  (`tcp_srtt_max`). On the phone's side, `ph_retrans` (retransmitted segments),
  `ph_rto` (retransmission timeouts) and `ph_lost` (a lost retransmit) are
  deltas of Linux's **system-wide** `Tcp:`/`TcpExt:` counters, read from
  `/proc/net/snmp` and `/proc/net/netstat`; while a window streams the stream
  is nearly all of the phone's TCP traffic, but other traffic on the phone is
  included, and an unreadable file leaves its field `-`.

The 5 s lines sample the last 2 s, so their frame rate and phase labels shift
against the script. The closing line (`stats total stream=N secs=… rx_frames=…
shown_frames=… hitch_n=… hitch_ms=… late_p99=… phone_n=… phone_frames=… kf=…
kf_req=… drop_ep=… drop_ms=… susp_n=… susp_ms=… bytes=… e2e_p50=…
e2e_p95=… covered_ms=… tcp_ooo_kb=… tcp_srtt_max=… ph_retrans=… ph_rto=…
ph_lost=…`) is complete over the window's whole life: counters survive the 5 s
samples and a config, `late_p99` and the e2e levels cover every shown frame,
and `covered_ms` is the time the window spent paused (occluded or minimised).
**The bench reads the totals line for every number in its table.**
The totals have no phases, so `shown_fps` and `late_p99` are whole-run values;
`kbps` is `bytes × 8 / secs` and the QP p95 is still the median of the 5 s
lines that carried a phone message (the totals line has no QP).

A run is **low-motion** when `rx_frames / secs` is under 20: the content did
not move, so the run cannot compare strategies. A run with `covered_ms > 0` is
marked **covered** and left out of the arm's medians. A run that produces no
closing line (a timeout) is marked **failed**; the bench writes the table and
the CSV anyway. Only the profile app's own PID supplies lines, and a run is
refused with `another window is open` when the same app logged a `stats
stream=` line in the last 10 s.

The clock offset survives a phone that sleeps: its `CLOCK_MONOTONIC` stops, so
the offset jumps between windows. A pong further from the estimate than
`(its RTT + the estimate's RTT) / 2 + 5 ms` restarts the estimate from that
sample (`clock offset: jump <ms>`), and the Mac pings at once when a window
opens and when the session is welcomed, besides the 15 s timer. Without that,
delays from 400 to 2500 ms in the first real-phone round were clock jumps, not
delay.

**The bench** opens a window through the Mac app's MCP tools (`open_app`, `swipe`, `close_window`) and runs a fixed script:

- 10 swipes at a fixed pace;
- a 3 s still;
- 10 fast flings;
- a 3 s still.

Every swipe alternates direction (up, down, up, …), so the list never rests at
an end and the picture keeps moving in both phases. It runs on a text-heavy
list (Settings) and on an image-heavy one. Every arm runs 3 times, interleaved
with the others, because the link's stalls come and go (the ping table above
changed between consecutive 15 s runs).

Under the table the bench prints one **resend block** per arm, over all its 5 s
lines: `hitch lines with resends a/b` (lines with `hitch_n ≥ 1` that also had
`ph_retrans ≥ 1` or `tcp_ooo_kb > 0`) beside `clean lines with resends c/d`
(lines with `hitch_n = 0` and `rx_fps ≥ 20` that did), and `no phone message: n`
for the lines left out. That is X0's answer: if hitches carry resends far more
often than clean motion does, TCP's head-of-line blocking is in the hitches.

## Measuring jank

"Janky" is the picture stopping **while the phone's content moves**. Three
causes produce that, and the bench adds them into one pair of numbers:

| Cause | Where | Counter | What it measures |
| --- | --- | --- | --- |
| link stall | Mac | `hitch_n`, `hitch_ms` | a sample handed to the display more than 50 ms after its capture step: `late = shownGap − ptsGap`; `late_p99` covers every frame, hitches or not |
| phone drop | phone | `drop_ep`, `drop_ms` | a send-queue drop episode and the pts span from the last frame sent before it to the frame (usually the keyframe) that ends it, minus one 60 fps interval |
| suspend (Q1) | phone | `susp_n`, `susp_ms` | the encoder took no input while the queue drained; an open episode's time so far is in every snapshot, so a suspend that never resumed still shows up |

A still is not jank: its heartbeat frames have a pts gap that matches the shown
gap, and a pause or config resets the Mac's reference. Per bench run:

```
jank_n  = hitch_n + drop_ep + susp_n
jank_ms = hitch_ms + drop_ms + susp_ms
```

The counters come from the closing totals line, so they cover the window's
whole life; `shown_fps` and `late_p99` are whole-run values too (the totals
have no phases). A totals line without `drop_ms` (an older phone) counts as
zero and marks the run `(no drop_ms)`, and a run whose `rx_frames / secs` is
under 20 is marked `low-motion`: the content did not move, so the run cannot
compare strategies. A run with `covered_ms > 0` is `covered` and leaves the
medians.

A run is **frozen** when a 5 s line in a swipe phase (the steady swipes or the
flings) has `rx_fps < 10`: the picture stopped while the phone's content moved.
A frozen picture produces no late frame, so its jank score is the best of the
round by accident; frozen runs are marked in the table and the CSV and leave
the medians, as `low-motion`, `covered` and `failed` runs do. The table's
`valid` column is how many runs made each arm's medians.

## Strategy switches

The candidate fixes are phone properties read once at a stream's configure
(open, resize, encoder rebuild); with none set the stream is today's, byte for
byte. The queue's two keys are read when a stream's first frame is queued.
The phone logs one line per stream per configure, e.g.
`stream 3 strategy: rc=cbr cap_kbps=16000 ir=60 queue_ms=100 overflow=suspend refine=on tos=0x88 stall=400/5000`,
or `stream 3 strategy: default`. A switch the codec refuses stays at today's
behaviour and the line says so in a closed token (`rc=cbr unsupported`,
`ir=60 unsupported`).

| Key | Values | Today | What it does | Fallback | Arm |
| --- | --- | --- | --- | --- | --- |
| `overflow` | `drop` / `suspend` | `drop` | `suspend` keeps queued deltas, stops encoder input (`PARAMETER_KEY_SUSPEND` 1) while the queue is over budget and resumes below half of it; no keyframe request, the −25 % bitrate reaction stays | past 4× the byte budget it drops and requests a keyframe as today, counted as a drop episode | `q1-suspend`, `q1q2-100`, `combo-a` |
| `queue_ms` | 30–1000 | 250 | the queue's video budget; the byte budget scales by `queue_ms / 250` | out of range clamps; junk is 250 | `q1q2-100`, `combo-a` |
| `rc` | `vbr` / `cbr` | `vbr` | CBR flattens frame sizes | codec without CBR keeps VBR and logs `rc=cbr unsupported` | `r1-cbr`, `combo-a` |
| `cap_kbps` | 1000–100000 | 8000 | the bitrate ceiling the per-pixel target is clamped to | out of range clamps; junk is 8000 | `r2-16`, `r2-25`, `combo-a` |
| `bpp_milli` | 50–500 | 120 | bits per pixel per frame × 1000 at 60 fps, before the cap | out of range clamps; junk is 120 | (no arm of its own) |
| `ir` | 0, or 10–600 frames | 0 | intra refresh instead of the 10 s keyframe: `KEY_INTRA_REFRESH_PERIOD` N and a 3600 s keyframe interval; keyframes still come on request | codec without `FEATURE_IntraRefresh` keeps the 10 s interval and logs `ir=60 unsupported` | `r4-ir60`, `combo-a` |
| `refine` | `off` / `on` | `off` | after 300 ms without a *new* encoded picture, one frame at 3× the current target (up to the cap) with a sync request; motion before it lands cancels and restores at once; one per still period | codec refusing the sync simply ends it at the 1 s timeout | `t1-refine`, `combo-a` |
| `tos` | 0–255 | 0 (unset) | `setTrafficClass(N)` on the accepted socket before the TLS handshake (AF41 is 136, `0x88`) | the OS refusing it logs `tos=0x88 unsupported` and the stream is unchanged | `n1-af41`, `combo-a` |
| `stall_ms`, `stall_every_ms` | 0 (off) or 50–2000 / 1000–30000 (default 5000) | 0 / 5000 | a stall on demand: while that stream has frames queued, the session's writer writes nothing to the socket for `stall_ms` every `stall_every_ms`, so the queue fills exactly as it does when the link stalls; other streams' frames wait too (it is the link) | 0 and junk are off; out of range clamps | `stall`, `stall-q1`, `stall-q1q2-100`, `stall-q2-500`, `stall-paced`, `stall-ir60` |

`stall_ms`/`stall_every_ms` are the round-2 fix for what round 1 could not
exercise: one drop episode in 32 runs and no suspend. Each injected stall logs
`stream N injected stall <ms>` (one line per pause), and the strategy line
names the switch (`stall=400/5000`). It is never on by default and no product
path sets it. `--arms-filter stall` runs the six stall arms alone, so a
reviewer does not need the whole list.

`refine`'s still signal is the encoded frame's size: a repeat of an unchanged
picture has the previous frame's size, which is the only input-silence signal
an encoder exposes (its Surface input is not readable). New size, or a
keyframe, means motion.

These are experiment switches for the bench, not product behaviour: they have
no spec rows, no on-screen setting, and every one defaults to today's stream.
The arms live in `tools/stream-bench/arms.json`; `combo-a` runs all of them
except `bpp_milli`. The bench's per-arm strategy line and its `susp_n`,
`susp_ms` and `refine_n` columns show which switches the phone applied.

### The Mac's switches

The Mac's three knobs follow the same rule: a `defaults` key in the app
profile's suite (`dev.pocketdeck.mac` for the person's app,
`dev.pocketdeck.mac.<profile>` for the e2e), read when a window opens or
resizes, never per frame. `stream.net` is read once when a session dials, so
its arms need the app restarted between runs (`n1-mac-video`, `n1-both` in
`arms.json`, skipped by the bench's default list). With no key set the picture
path and the size request are exactly today's; a window logs one line,
`stream 3 mac strategy: present=paced pixels=panel net=video`, or
`stream 3 mac strategy: default`.

| Key | Values | Today | What it does | Arm |
| --- | --- | --- | --- | --- |
| `stream.present` | `immediate` / `paced` | `immediate` | `paced` holds decoded samples (at most two) and hands the oldest to the layer on each display refresh. A third arrival drops the oldest and counts `mac_drop`; a keyframe waiting is kept, and a drop asks the phone for one keyframe per 1.5 s so the decoder restarts. Adds about one frame of latency. | `m1-paced` |
| `stream.pixels` | `backing` / `panel` | `backing` | On a scaled display the request becomes backing pixels × panel width ÷ display backing width, still encoder-aligned. The panel width is the mode Core Graphics flags native, else the largest point-size mode's pixel size. The settled capped picture stretches over the window; an unscaled display is unchanged. | `m2-panel` |
| `stream.net` | `default` / `video` | `default` | `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` on the dialled stream socket before connect (N1's Mac half); the session line's `net_svc` is the socket's own read-back. | `n1-mac-video`, `n1-both` |

On the e2e's own virtual display (1280×800 at 1x, or 2560×1600 backing at 2x)
the reported panel width is already the display's backing width, so
`stream.pixels=panel` is a no-op there; the K2 factor tests are its proof. The
factor on the person's main display (3840×2160 panel, 6016×3840 backing) is
0.638.

## First real-phone round (2026-11-05)

All 11 default arms × 3 interleaved runs on the person's phone (v145, phone locked and dozing, Settings), 12:47–13:02. The table is per arm: `jank_ms` for each valid run, and the run's bitrate. A run is invalid when the swipe line saw no frames (the picture did not move).

| Arm | jank_ms per valid run | Invalid runs | kbps | Note |
| --- | --- | --- | --- | --- |
| baseline | 162, 0, 217 | – | ~6100 | |
| q1-suspend | 61, 262 | 1 | ~6700 | never suspended (`susp_ms=0` in every run) |
| q1q2-100 | 896, 161 | 1 | ~5800 | never suspended |
| r1-cbr | – | 3 | ~4500 | **the picture freezes**: 0–4 fps during the swipes in all 3 runs, though the phone sent ~4.5 Mbps |
| r2-16 | 987, 163, 1070 | – | ~5900 | the most hitches |
| r2-25 | 166, 282, 610 | – | ~6300 | the only drop episode of the round (166 ms) |
| r4-ir60 | 108, 309 | 1 | ~6200 | 1 keyframe per run instead of 2 |
| t1-refine | 0, 0 | 1 | ~6300 | 9–10 keyframes per run (one per still) |
| m1-paced | 50, 203 | 1 | ~6200 | |
| m2-panel | 1198, 777, 471 | – | ~4600 | fewer bits, more hitches; the window resizes once after it opens |
| combo-a | 0, 0 | 1 + 1 failed | – | contains `rc=cbr`, so not valid; run 3's window was covered by another window and paused |

What it shows:
- **The link was clean.** One drop episode in 32 runs, no suspend. Every jank in this round is a hitch: a frame shown 50–200 ms later than the phone made it, from link jitter. The queue arms (Q1, Q2) were never exercised, so this round cannot rank them. The stalls that cause the person's drop-and-keyframe loop need a link that stalls on demand (next round).
- **R1 (CBR) is broken on this encoder** for surface input. It must not ship until the freeze is understood.
- **More bits mean more hitches** (R2-16). Raising the cap is not the fix for jank.
- **The rest is within the noise.** Baseline alone spans 0–217 ms over three runs.

What the round found wrong with the measurement:
- **The capture→display delay is unreliable across windows.** The phone's CLOCK_MONOTONIC stops while it sleeps between windows, and the Mac's offset estimate keeps the lowest-RTT sample of 30 s, pinging every 15 s. In one window the delay read a constant 2.36 s while the encoder (14 ms) and the queue (0.6 ms) were fast and frames flowed. Delays from 400 to 2500 ms in this round are clock jumps, not delay.
- **Frame rates are sampled.** Each 5 s line measures fps over its last 2 s only, and the phase labels shift against the script. Counters (hitches, drops, suspends, keyframes) are complete.
- **A frozen phone screen is invisible to the hitch rule.** When the phone's own rendering stalls, the capture times stall too, so `late` stays near 0. Some invalid runs outside CBR look like this: no frames during swipes, then a burst. The phone awake gave 85 fps during the swipes at 11:23, dozing gave 55–60.
- **A failed run lost the whole table.** The bench exited on the last run's missing line without writing the CSV.

## Second real-phone round: the stall on demand (2026-11-05)

The six stall arms × 3 interleaved runs on the person's phone (v146, phone locked and dozing, Settings), 15:51–15:59, with `stall_ms=400` every 5 s (`stream N injected stall 400`, about four per 22 s run). Numbers from each window's closing `stats total` line; `jank_ms` per run.

| Arm | jank_ms per run | drop_ms | kf_req | Note |
| --- | --- | --- | --- | --- |
| stall (today's policy) | 1418, 613, *0* | 249, 216 | 1, 1 | run 2 got no picture for its 22 s (10 frames, `phone_frames=0`): the slow first frame of ISS-10, not the stall |
| stall-q1 | *437, 485, 85* | 0 | 0 | **frozen**: the encoder stayed suspended (see below); 502–735 frames against about 1,250 |
| stall-q1q2-100 | *461*, 513, *0* | 0 | 0 | runs 1 and 3 frozen (33 frames in run 3); run 2 recovered and is the only valid Q1 run |
| stall-q2-500 | 1154, 1719, 1218 | 350, 0, 0 | 1, 0, 0 | the 500 ms queue rides out the stall without a drop in 2 of 3 runs, but every stall becomes a long hitch |
| stall-paced | 669, 1135, 1077 | 267–607 | 1–2 | |
| stall-ir60 | 572, 1519, 587 | 161–710 | 1–4 | |

Italics: not valid (frozen or no picture). Every arm pays the injected stall itself (about 400 ms of nothing per stall that lands in motion), so the policy's own cost is the part beyond it: today's policy adds a drop and a keyframe per run, as predicted.

What it shows:
- **The stall switch works**, and today's policy does what the session log of 2026-11-04 showed: deltas dropped, a keyframe asked for, the picture held until it arrives.
- **Q1 is broken, not ranked.** Under a stall, skip-at-source can leave the encoder suspended for the rest of the window:
  - stream 15: the pressure transition (encoder thread) and the drain transition (writer thread) landed in the same millisecond, and the encoder's SUSPEND was applied after the resume. The machine said flowing, the encoder stayed suspended: 33 frames in 21.8 s;
  - stream 14: suspended 10.7 s into the window and never resumed: the resume check gives up when the backlog is empty, which is the most drained state there is.
  - Fix on `fix/q1fix` (the state applied under one lock, empty counts as drained, a 1 s suspend timeout); Q1 is re-run after it.
  - The same fix found a fault in **today's default policy**: the queued span ran from the first frame of a backlog until the queue emptied, not from the oldest frame still queued. A writer one frame behind for 250 ms of a scroll therefore dropped every delta and asked for a keyframe with about 33 ms actually queued. That is the drop-and-keyframe loop of the person's 2026-11-04 session without any stall of the link, and it is fixed on main from v147, so rounds 1 and 2's baseline is not round 3's.
- **A longer queue is not the answer.** 500 ms avoids most drops but turns every stall into a hitch of the same length, with the highest jank of the round.
- **Paced display and intra refresh are within the noise** of today's policy under a stall.
- **Intra refresh corrupts the picture after a drop.** The person watched the last run (`stall-ir60`, stream 18) and saw broken blocks and doubled text in the lower half at 15:59:21 (screenshot, not kept: it shows personal details). The phone had dropped deltas and asked for a keyframe at 15:59:14.8 (`drop_ep=1 drop_ms=161 kf_req=1`); it encoded 1,378 frames and the Mac received 1,269, more than the episode's gap accounts for. Likely cause: with `KEY_INTRA_REFRESH_PERIOD` set, the key-flagged frame the queue resumes on is not a full IDR, so the decoder keeps predicting from deltas it never got, and scrolling copies the damage around instead of letting the refresh band heal it. R4 must not ship, and its numbers here don't count, until the frame a drop resumes on is proven to be an IDR (NAL type 5) in that mode. No metric saw it: jank, QP and the counters can't tell a corrupted picture from a clean one.

What the round found wrong with the measurement:
- **A frozen picture scores best.** The two frozen Q1 runs had `jank_ms` 85 and 0. The hitch rule needs a frame to be late, and a frozen picture sends none; `susp_ms` counted only episodes that ended (0–19 ms for a 10 s suspend). The bench now has to mark a run `frozen` when a swipe line has almost no frames, and count an open suspend.
- **The medians counted low-motion runs** (today's policy's median of 613 included the run with no picture).
- **Corruption is invisible to the numbers.** A run needs a check that the frame a drop resumes on is an IDR (the Mac can read the NAL type of every key-flagged frame it decodes), and the bench should keep one screenshot per swipe phase through the automation tool, for the reviewer to look at.

Raw data: `.agent/stats/round2/` (not in the repo).

## Third real-phone round: Q1 after its fix, against the fixed default (2026-11-05)

Four arms × 3 interleaved runs on the person's phone, 21:54–22:01, with v147:
- the setup: the phone locked, dozing and unplugged at 37 %; Settings; Wi-Fi pings 5–427 ms;
- every stall arm has `stall_ms=400` every 5 s, so four injected stalls per 22 s run.

`jank_ms` is per run, from each window's closing `stats total` line. Drops and suspends are counted from the phone's log.

| Arm | jank_ms per run | median | hitch_ms | drop_ms | susp_ms | Phone: drops / suspends per 4 stalls |
| --- | --- | --- | --- | --- | --- | --- |
| baseline (today's default, fixed) | 56, 0, 524 | **56** | 56, 0, 524 | 0 | 0 | none |
| stall (today's default, fixed) | 1333, 250, 1091 | **1091** | 950, 0, 474 | 383, 250, 617 | 0 | 1, 1, 2 drops |
| stall-q1 | 1453, 1199, 1160 | **1199** | 1275, 1012, 891 | 0 | 178, 187, 269 | 1, 1, 2 suspends, no timeout |
| stall-q1q2-100 | 1346, 774, 1441 | **1346** | 971, 454, 974 | 0 | 375, 320, 467 | 2 suspends each, no timeout |

What it shows:
- **Q1 works now, and it loses.**
  - Every suspend resumed within 0.1–0.4 s, and the 1 s timeout never fired.
  - The phone produced 722–759 frames per run against 752–790 for the baseline, so nothing froze.
  - Skip-at-source turns the stall into a hitch plus a suspend. The total is no smaller than the fixed default's drop, so Q1 stays off and is not a preset candidate.
  - A 100 ms queue on top of Q1 (Q2) is worse again.
- **The fixed default drops less.** It dropped on 1–2 of the 4 stalls per run; in round 2 the old rule dropped on most stalls. What is left is the injected stall itself (about 400 ms of nothing per stall in motion), and no queue policy can hide that.
- **The baseline is nearly clean:** a median of 56 ms of jank per 22 s run, with no drops. Round 1's baseline isn't comparable (the default-policy fault, above).
- **No sign that TCP resends make the hitches (X0).**
  - Baseline: 2 of 2 hitch lines had resends, and so did 2 of 3 clean lines. Resends don't tell hitches from clean lines.
  - `tcp_ooo_kb` was 0 in every run, and `tcp_srtt_max` stayed at 20–27 ms.
  - On this link the case for UDP with FEC (X1) is not made. X1 stays logged, but below the encoder work. A round on a worse link (a busy channel, the person's real day) can still reopen it.

What the round found wrong with the measurement:
- **The `frozen` mark has false positives.** The Mac's 5 s line reports `rx_fps` over a 2 s sliding window, so one line samples only 2 s of the 5. Two healthy runs got the mark: streams 2 and 8, with 695 and 699 frames against 622–790 for the others, from a single swipe line at 0.0 fps. The table above counts every run.
  - The rule now reads the longest gap between received frames (`max_gap_ms`) from the closing totals line, over the run's whole life outside covered time: a run is frozen when it is over 2,500 ms. The 5 s `rx_fps < 10` rule survives only for older logs without the field.
- **One of those lines may be a real 2 s gap that no counter saw.**
  - Stream 2's line at 21:55:17 had no frames for 2 s in the middle of the swipes (the Mac logged a swipe every 0.7 s). That came 4 s after the phone dropped deltas and asked for a keyframe.
  - Yet the next line counted 912 ms of freezes and no gap that long.
  - Either the gap wasn't there, or something resets the freeze baseline after a drop (a new `VIDEO_CONFIG` resets it). `max_gap_ms` now survives a config, and both ends time the recovery (below), so the next real-phone run settles it. That gap may be the "freeze" half of the person's freeze-then-blocky loop.

Raw data: `.agent/stats/round3/` (not in the repo).

### How the resuming frame is counted

R4 stays off the table until the frame a drop resumes on is proven an IDR. Both
ends count it by NAL type, never by bytes:

- **Phone:** each output buffer the encoder flags key has its access unit's
  leading start codes scanned (SPS/PPS/SEI, up to the first slice).
  `key_idr` counts a buffer with a type-5 slice; `key_not_idr` counts a
  key-flagged buffer without one. Both are in the 2 s `stream.stats` message
  and the closing `stream N totals:` line, and the first three non-IDR frames
  per stream write `stream N key nal=<types>`. The types say why: `6,1` is an
  SEI plus a P slice, the shape intra refresh emits when it flags a
  recovery point rather than an IDR.
- **Mac:** the same test on the wire flag and the units it actually decodes.
  `key_not_idr=` goes in the 5 s line and `stats total`; `ph_key_not_idr=` is
  the phone's own count from its messages. The first three non-IDR frames per
  stream write `stream N key nal=<types>`.
- **Why:** with intra refresh the encoder may flag a recovery-point frame as
  key. The send queue resumes on that flag; without a type-5 slice the decoder
  keeps predicting from frames it never got, and scrolling spreads the damage.
  Jank, QP, byte counts and freeze counters cannot see that; a NAL type can.
- **Both ends time a drop episode:** the phone logs `stream N drop: <n>
  dropped, key after <ms> ms, nal=<types>` from the first discarded delta to
  the key frame's send. The Mac arms on a `stream.stats` message with
  `dropEp > 0` and logs `stream N drop recovered after <ms> ms` at its first
  type-5 frame; its clock starts when the message arrived, so its number is an
  observation, not the phone's in-phone time.
- **`max_gap_ms`** is the longest interval between received frames, outside
  covered time, in each 5 s line (since the previous line) and the totals
  (the whole run). A `VIDEO_CONFIG` in the middle of a gap does not hide it.

One-boot emulator round (2026-11-05, arms `stall` and `stall-ir60`, one run
each): the encoder applied `ir=60`, and both ends' `key_not_idr` were 0. The
resuming frames carried a type-5 slice (`nal=5`, and one `nal=0,5` with a
leading type-0 unit), so the emulator does not reproduce the person's
corruption. The real phone decides R4.

## Presets, later

Once the numbers are in, two presets fall out of the winners. Neither is exposed until the person picks:

- **Quality:** maintain resolution, T1 on, M1 on. Under pressure, fps drops and text stays sharp.
- **Performance:** maintain frame rate, Q2 at 50 ms, M1 off. Under pressure, QP rises and 60 fps stays.

The default for app windows is likely quality, since they are mostly text. A game or video app could switch to performance on its own later.

## Sources

- [Sunshine: NVENC options (VBV/HRD single-frame buffer)](https://docs.lizardbyte.dev/projects/sunshine/master/nvenc__config_8h_source.html)
- [A Sunshine fork's release notes: capture on present, latency log](https://github.com/MoreOrLessSoftware/Sunshine/releases/tag/mlsoft-r6)
- [A Moonlight Android client: "Prefer lowest latency" vs "Prefer smoothest video"](https://github.com/derflacco/moonlight-android/discussions/20)
- [W3C WebRTC: Chrome's default degradation preference for screen sharing](https://lists.w3.org/Archives/Public/public-webrtc-logs/2024Nov/0035.html)
- [Chrome: "maintain-framerate-and-resolution" intent to ship](https://groups.google.com/a/chromium.org/g/blink-dev/c/FUlvv_Lmk-s)
- [RustDesk: re-encoding static frames after scrolling](https://github.com/rustdesk/rustdesk/pull/16128)
- [IronRDP: progressive refinement and a lossless text codec (proposal)](https://github.com/Devolutions/IronRDP/issues/1158)
- [Android: low-latency media](https://source.android.com/devices/media/low-latency-media)
- [Android: MediaFormat keys](https://developer.android.com/reference/android/media/MediaFormat)
- [scrcpy manual: bitrate, max fps, render only the latest frame](https://manpages.ubuntu.com/manpages/focal/man1/scrcpy.1.html)
- [L4S congestion control for cloud real-time streaming](https://ieeexplore.ieee.org/document/10539241/)
- [L4S-enabled adaptive WebRTC video (MMSys '26 demo)](https://dl.acm.org/doi/10.1145/3793853.3798195)
- [Adaptive bitrate in cloud gaming (GamingAnywhere, WPI)](https://digital.wpi.edu/downloads/pc289k608?locale=en)
- [Android: `PARAMETER_KEY_QP_OFFSET_RECTS` (region of interest)](https://learn.microsoft.com/en-us/dotnet/api/android.media.mediacodec.parameterkeyqpoffsetrects?view=net-android-37.0)
- [AOSP: OEM guidance for region-of-interest encoding](https://source.android.com/docs/core/media/roi)
- [Apple: `VTLowLatencySuperResolutionScalerConfiguration`](https://developer.apple.com/documentation/videotoolbox/vtlowlatencysuperresolutionscalerconfiguration)
- [MS-RDPEGFX: YUV420p stream combination for YUV444 mode (AVC444)](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/8131c1bc-1af8-4907-a05a-f72f4581160f)
- [Sunshine: FEC protecting video frames against packet loss (pull request)](https://github.com/LizardByte/Sunshine/pull/4926)
- [Moonlight Android: reference frame invalidation after packet loss (pull request)](https://github.com/moonlight-stream/moonlight-android/pull/1565)
