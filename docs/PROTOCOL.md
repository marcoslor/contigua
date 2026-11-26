# Contigua wire protocol — v4

The single source of truth for Mac ⇄ phone traffic. Both sides MUST implement
exactly this. Change it here first, then in code.

## Transport

- **LAN, and optionally a direct path.** The default transport is the LAN; a
  build compiled with the direct provider can also carry the session over
  Wi-Fi Aware (see "Paths"). The phone always listens on TCP (ephemeral port)
  on the LAN and advertises it over mDNS/DNS-SD as service type
  `_contigua._tcp.` with TXT records:
  `v=1` (the discovery record's generation), `id=<deviceId>` (stable random
  hex, 16 chars), `name=<device name>`, `model=<Build.MODEL>`. No fingerprint
  or other tracking identifier rides in the TXT. While the phone's "Allow
  connections" switch is off it stops advertising and keeps the listener up:
  a Mac that already has the address is refused (see "Error codes"), and
  turning the switch back on advertises the same port again. A Mac remembers
  the last address where a session reached `welcome`, so it can still reach a
  phone whose advertisement it cannot see.
- **TLS 1.3, mutual, pinned — no plaintext, no v1.** The phone wraps every
  accepted connection in a platform `SSLSocket` (Conscrypt) and the Mac dials
  with NIOSSL/BoringSSL (docs/design/e2ee.md §1/§2). Both ends: TLS 1.3 only,
  client auth required, session resumption and 0-RTT disabled, and the peer
  certificate pinned (the phone pins the Mac's certificate fingerprint, the
  Mac pins the phone's). There is no plaintext phase and no v1 fallback: a
  client that does not complete the handshake is closed without a byte.
- The Mac connects **one or more TCP connections per phone**: each connection is
  a **path**, and **the session spans the paths** ("Paths"). At first there is
  one path, and everything — control, input and every video stream — is
  multiplexed on it, exactly as before. A later path can be added to the same
  session, and the session survives the loss of any one of them. Every path does
  its own full TLS handshake; TLS is never resumed across paths.
- Both ends set `TCP_NODELAY` on every path. Byte order is **big-endian**
  everywhere.

## Framing

Every message is one frame:

```
u32 len        // number of bytes that follow this field (type + stream + payload)
u8  type
u32 stream     // 0 = session-level; otherwise a window stream id chosen by the Mac.
               // JSON frames: equals the message's "stream" field if it has one, else 0;
               // the JSON field is authoritative.
u8[len-5] payload
```

Max frame size 8 MiB; a receiver that sees a larger `len` closes the session.

| type | name | dir | payload |
|---|---|---|---|
| `0x01` | JSON | both | UTF-8 JSON object, always has string field `"t"` |
| `0x02` | VIDEO_CONFIG | phone→mac | `u8 codec` (1 = H.264/AVC, 2 = HEVC) · `u16 width` · `u16 height` · Annex-B parameter sets (AVC: SPS+PPS; HEVC: VPS+SPS+PPS) |
| `0x03` | VIDEO_FRAME | phone→mac | `u64 ptsUs` · `u8 flags` (bit0 = keyframe) · Annex-B access unit |
| `0x04` | AUDIO_CONFIG | phone→mac | `u8 codec` (2 = Opus, 3 = AAC-LC) · `u32 sampleRate` · `u8 channels` · `u16 frameMs` · codec setup bytes (Opus: empty; AAC: ASC) |
| `0x05` | AUDIO_FRAME | phone→mac | `u64 ptsUs` · one encoder packet (one Opus frame or one AAC access unit) |
| `0x06` | VIDEO_CHUNK | phone→mac | `u64 ptsUs` · `u8 flags` (bit0 = keyframe) · `u16 index` · `u16 count` · one ≤16 KiB fragment of the access unit; see "Video rules" |
| `0x10` | TOUCH | mac→phone | `u8 action` (0 down, 1 up, 2 move, 3 cancel) · `u8 pointerId` · `f32 nx` · `f32 ny` — one frame per pointer; the phone stamps each event with its arrival time, so the Mac sends them as they happen (a drag's cadence is its fling velocity) |
| `0x11` | SCROLL | mac→phone | `f32 nx` · `f32 ny` · `f32 hscroll` · `f32 vscroll` — mouse-wheel units, injected as `ACTION_SCROLL` (`SOURCE_MOUSE`) with these as `AXIS_HSCROLL` / `AXIS_VSCROLL` at (nx, ny). `vscroll > 0` = content moves down (wheel up), `hscroll > 0` = content moves left (wheel right). One unit is one wheel notch (Android's default 64 dp scroll factor); fractions are fine. The Mac sends SCROLL for mouse wheels only: a trackpad's two-finger scroll is a one-finger drag in TOUCH (DOWN, MOVEs, UP), so Android's own drag, overscroll and fling apply |
| `0x12` | KEY | mac→phone | `u8 action` (0 down, 1 up) · `u32 keycode` (Android `KEYCODE_*`) · `u32 metaState` |
| `0x13` | HOVER | mac→phone | `u8 action` (0 enter, 1 move, 2 exit) · `f32 nx` · `f32 ny` — the Mac pointer over the video with no button down, injected as `ACTION_HOVER_ENTER`/`MOVE`/`EXIT` (`SOURCE_MOUSE`, tool type mouse) at (nx, ny) on the stream's display. Moves are coalesced on both sides (at most one per 16 ms; the phone keeps only the newest when it is still injecting). No hover while a button is down: the Mac sends EXIT, then the TOUCH DOWN. A phone that does not know this type ignores it |
| `0x20` | APK_DATA | mac→phone | the next bytes (≤ 1 MiB) of an APK install; `stream` = the install `id`; see "APK install" |
| `0x21` | SHARE_DATA | phone→mac | the next bytes (≤ 1 MiB) of a shared file; `stream` = the share `id`; see "Share phone → Mac" |
| `0x22` | DROP_DATA | mac→phone | the next bytes (≤ 1 MiB) of a file dropped on a window; `stream` = the drop `id`; see "Drop Mac → phone" |
| `0x23` | CLIP_DATA | both | the next bytes (≤ 1 MiB) of a clipboard image; `stream` = the image `id`; see "Clipboard images" |
| `0x24` | FS_DATA | both | the next bytes (≤ 256 KiB) of an `fs.read` or `fs.write`; `stream` = the request `id`; see "Phone files" |
| `0x30` | RELIABLE | both | one reliable frame, wrapped: `u64 seq` · `u8 innerType` · `u32 innerStream` · `u8[] innerPayload`; `len` = 18 + innerPayload, the outer `stream` mirrors `innerStream`; see "Paths" |
| `0x31` | ACK | both | `u64 ack` = the next seq this side expects; `stream` 0; `len` = 13 |

`nx`,`ny` are normalized `[0,1]` in the stream's video coordinates (top-left
origin). The phone maps them to the stream's current virtual display size.
Input frames carry the window's `stream` id; the phone stamps the matching
display id on every injected event.

`f32` = IEEE-754 single, big-endian.

### Video rules

- Order on open: `window.opened` (JSON), then `window.content` and VIDEO_CONFIG, then
  VIDEO_FRAMEs, the first a keyframe. `window.opened` names the display's task id,
  so a phone sends it once the launch has made that task; video that arrives
  meanwhile waits (the reply, then the CONFIG and its keyframe).
- **`window.content`** (JSON, phone→mac, sent on the same lane just before every
  VIDEO_CONFIG): `{"t":"window.content","stream":N,"x":X,"y":Y,"w":W,"h":H}` is where the
  picture sits in the config's frame, in frame pixels with a top-left origin. It is
  required: a VIDEO_CONFIG without one is dropped by the Mac. An app window's picture is the
  whole frame. A phone mirror's frame may carry black outside its picture (the encoder's
  size and the screen's aspect differ; the picture is centred); the Mac shows only the
  picture, scaled to fill its window, and its aspect lock follows the picture's, not the
  frame's. Input maps over the picture, which is the screen.
- One VIDEO_FRAME = exactly one access unit (one MediaCodec output buffer).
- **Large access units may arrive as VIDEO_CHUNKs** when the Mac's hello has
  `videoChunks:true`. One access unit becomes `count` fragments of at most
  16 KiB, each carrying the same `ptsUs` and `flags` and its `index` (0-based).
  The fragments of one stream go on the wire in index order and contiguous
  within that stream: audio, JSON and another stream's frames may be written
  between them (MEDIA-16), but never another frame of the same stream — a
  partly sent frame keeps the head of its lane. The receiver reassembles by
  `(stream, ptsUs, flags)` and only then hands the decoder one access unit,
  exactly as a whole `VIDEO_FRAME` would. A missing fragment (or a stub the
  phone discarded, e.g. at a drop episode or a new control frame) costs that
  one frame: the Mac discards the incomplete unit, treats it as a break of the
  reference chain (no delta reaches the decoder until a keyframe, MEDIA-19),
  and the next keyframe restarts cleanly. A phone sends whole `VIDEO_FRAME`s
  to a Mac without the field.
- **Codec.** HEVC is the default when the Mac's `hello.codecs` listed it as
  hardware-decodable, the phone has a hardware HEVC encoder
  (`MediaCodecInfo.isHardwareAccelerated` on API 29+, a name without the
  platform software prefixes below it), and that encoder accepts the size.
  The bench's `codec=avc` forces H.264; no value, `codec=hevc` and junk mean
  "HEVC when possible". Otherwise the stream stays H.264 and the phone writes
  one line, `codec=hevc unsupported: <mac|encoder|size>`, naming the first
  condition that failed. IF the chosen HEVC encoder fails to create, configure
  or start THEN the phone retries the same stream once with H.264, writes
  `codec=hevc unsupported: configure`, and keeps HEVC off for the rest of the
  process. `VIDEO_CONFIG`'s codec byte names every stream's codec (1 = avc,
  2 = hevc). A hello with no `codecs` (an older Mac) means AVC only, and a
  phone that predates the field sends 1 in every config, so an older phone's
  stream reads as AVC.
- **NAL types are codec-aware.** H.264's type is `byte & 0x1F`; HEVC's is
  `(byte >> 1) & 0x3F`. HEVC parameter sets are VPS 32, SPS 33 and PPS 34; IDR
  slices are 19 and 20, CRA 21 is a key frame that is **not** an IDR, and slices
  are 0–31. `key_idr`/`key_not_idr`, `kf`, the drop line's `nal=` and the Mac's
  `key_not_idr` keep their meaning for both codecs: a wire-keyed frame holding
  an IDR slice (AVC 5; HEVC 19 or 20) counts as an IDR, and a HEVC CRA counts
  `key_not_idr`. Both ends print the codec's own type numbers plus `codec=` once
  in the snapshot.
- **A codec the Mac cannot decode is refused.** IF a `VIDEO_CONFIG` names a codec
  the Mac does not decode (its own hardware test says no, or an unknown number)
  THEN the Mac refuses that stream with one log line naming the stream id and
  the codec, shows its existing refusal state (the opening cover's refusal while
  it is opening; a refused stream once live), and never hands the bytes to
  another codec's decoder.
- On resize the phone sends a **new VIDEO_CONFIG** (new size) followed by a
  keyframe, then `window.resize.ack`. The Mac must rebuild its format description on
  every CONFIG. Frames received before the new CONFIG are old-size frames and may be
  shown or dropped. `window.resume` of a paused stream is always answered with
  CONFIG + keyframe (the encoder resends its config, or is rebuilt); `window.keyframe`
  asks for a keyframe (one sent moments before already answers it). A resize that changes only the dpi keeps the frame size, so it
  answers with the ack alone ("density"): every app relayouts onto the surface the
  running encoder still reads. A request the display already shows answers "same",
  and one the phone cannot apply (no such stream, or a size of zero) answers
  "refused": every `window.resize` a phone reads is answered. The Mac keeps one
  request in flight and sends only the newest value that waited behind it, so
  re-attaching the encoder never overlaps with the last answer. A phone that
  answers neither the request nor a CONFIG (an older build, a paused stream, a
  refused resize) does not hold the window: the Mac counts the request settled
  when the ack or CONFIG arrives, or when the resize stall limit passes
  (`density_burst_stall_ms`, NFR.md).
- The display content being static is not silence. Two mechanisms say so, and
  neither changes the picture: repeat-previous where the encoder honours it —
  `KEY_REPEAT_PREVIOUS_FRAME_AFTER` repeats the last frame at least every
  500 ms while a stream is open — and `window.still` where it does not. After
  1000 ms without an encoder output buffer a live stream sends
  `{"t":"window.still","stream":N}` from its own drain loop, and sends it
  again once a second while the silence lasts; a backlogged socket produces no
  `still`, so backpressure cannot hide a real stall. A live stream is
  therefore never quiet for long, which lets the Mac tell a static picture
  from a stalled encoder (it says "Not responding" after 1.5 s without frames
  or a `still`).
- Backpressure: the phone never queues more than ~250 ms of video per stream.
  If the socket can't keep up it drops non-key frames for that stream until the
  next keyframe, and requests one from the encoder (`PARAMETER_KEY_REQUEST_SYNC_FRAME`).
  JSON and frames for other streams are never blocked behind a stalled stream's
  backlog (send-queue priority: JSON > keyframes/config > delta frames).
- `window.quality` is optional and best-effort: `bitrate` is a target in bps,
  `maxFps` an upper bound for the encoder. The phone clamps both to what its
  encoder supports, may apply only one of them, and is free to ignore the whole
  message (older phones do). After a backpressure drop the phone lowers a
  stream's bitrate on its own (with a floor) and grows it back once frames keep
  up, so an explicit `bitrate` is a target to recover to, not a guarantee.
  The Mac does not send `window.quality` yet (the fakephone selfcheck does; a
  WAN quality cap will).

### Stream stats

`stream.stats` is measurement only: it changes no encoder, queue, size or frame
rate. The Mac turns it on with `{"t":"stream.stats","on":true}` (session-wide,
after `welcome`) and off with `on:false` when its last stream window closes; an
ask the session refuses before the link is ready is sent again when the session
becomes ready with windows open. While on, the phone sends one message per
streaming window every **2 s**; a paused window sends none, and off (or no Mac)
sends none. A phone with no Mac connected runs nothing new. Numbers only, never
titles, package names or pixels: the stream id, counts, sizes, rates and timings
are all that may appear.

The phone's message covers the window since its previous one (or since stats
turned on): `frames` out of the encoder, `kf` buffers the encoder flagged key,
`keyIdr` and `keyNotIdr` how many of those access units do and do not carry a
type-5 slice before their first slice (scanned from NAL start codes, never
bytes: a recovery-point frame in intra-refresh mode is flagged key but holds a
P slice), `kfReq`
keyframes requested, `bytes` queued, `drop` deltas the send queue discarded,
`dropEp` drop episodes (a discard run until the next keyframe), `dropGapMs`
how long the picture was missing across those episodes, `skip` frames dropped by
the max-fps fallback and `targetBps` the current target bitrate. Each drop
episode's gap is the `ptsUs` span from the last frame sent before its first
discarded delta to the first frame sent after it (the keyframe), minus one
60 fps interval, at least zero, summed in milliseconds; an episode still open
at a snapshot lands, whole and once, in the window that sees it resume.
`susp`/`suspMs` are Q1's encoder-suspend episodes and the milliseconds they
covered: an episode still open at a snapshot counts its time so far, and the
next snapshot carries on from there, so the sum over snapshots is the
episode's whole time, counted once. `refine` is T1's refined still frames
sent.
`retrans`, `rto` and `lost_retrans` are the phone's **system-wide** Linux TCP
counter deltas since its previous message: retransmitted segments
(`/proc/net/snmp` `Tcp: RetransSegs`), retransmission timeouts and lost
retransmits (`/proc/net/netstat` `TcpExt: TCPTimeouts` and `TCPLostRetransmit`),
each parsed by header name and absent when that file could not be read (the
stream is nearly all of the phone's TCP traffic while it streams, but not
all). A counter that went backwards sends no delta, never a negative.
`encP50`/`encP95` are the capture (`ptsUs`, CLOCK_MONOTONIC µs) to output-buffer
dequeue delays; `queueP50`/`queueP95` are the delta's `SendQueue` enqueue to its
socket write finishing. `qpP50`/`qpP95` are the per-frame average QP from
`KEY_VIDEO_QP_AVERAGE`; `qpAvg` is the mean of that window's frame averages,
and both are absent unless the codec reports
`FEATURE_EncodingStatistics` (the phone then sets
`KEY_VIDEO_ENCODING_STATISTICS_LEVEL` to level 1). `codec` names the stream's
codec (`avc` or `hevc`). An absent optional field
means "no measurement", never zero.

#### No-frame episodes (WIN-66, ISS-10)

A window that produced no encoded frame 1500 ms (`first_frame_ms`, NFR.md)
after its display was created gets one record, carried by the optional
`noFrame` object of that stream's next `stream.stats` message:

| Field | Meaning |
| --- | --- |
| `ep` | the phone's id for the episode; the app's private ring of 20 upserts by it, so an end updates the entry instead of adding one |
| `ms` | milliseconds from the display's creation to this record |
| `phase` | the encoder's closed token: `empty`, `opening`, `prepared`, `draining`, `paused`, `suspended`, `paused+suspended`, `swapping`, `released` |
| `display` | `none`, `mirror` or `virtual` |
| `task` | `launched` when a task was launched on the display, `none` when it had none, `unknown` when the phone cannot read its task list |
| `on` | the stream display's own state: `on`, `off`, `doze`, `doze-suspend`, `vr`, `on-suspend` or `unknown` |
| `keyguard` | `showing`, `hidden` or `unknown` (read only; nothing unlocks the phone) |
| `doze` | `active`, `light` (`isLightDeviceIdleMode`), `idle` (`isDeviceIdleMode`) or `unknown` |
| `screen` | display 0's screen state, as `state.screen`: `on`, `off` or `unknown` |
| `nudge` | redraw nudges the stream made (the input-side evidence; the codec's Surface input exposes no counter) |
| `out`, `kf`, `bytes` | the encoder's output buffers, key buffers and encoded bytes over the stream's whole life |
| `outcome` | absent while the episode is open; `late` when the first frame arrived, `closed` when the stream closed first |
| `waitedMs` | with `outcome`, milliseconds from the display's creation to that end |

Ids, counts, durations and closed tokens only: no app name, label, title or
text. The phone sends each state of the episode once; a stream that closes
before its next 2 s message carries its ended episode in one final
`stream.stats` (no window counters), and with stats off the phone's private
ring and its field log are the record. The Mac prints the record once as
`stream <id>: no frame for <s>s phase=<...> display=<...> task=<...>
on=<...> keyguard=<...> doze=<...> screen=<...> nudge=<n> out=<n> kf=<n>
bytes=<n>` and its end once as `stream <id>: no frame ended
outcome=<late|closed> after <ms>ms`; a repeated field with the same `ep` prints
nothing new. The phone's closing totals line carries
the same `codec=` and `qp_avg=` over the stream's whole life, with `qp_avg=-`
when the encoder never reported a QP.

The Mac's clock handshake: `ping.monoUs` is the Mac's CLOCK_MONOTONIC µs when
the ping went out, `pong.now` the phone's at the answer. The Mac keeps the
lowest-RTT sample of the last 30 s as the offset
(`offset = now − (monoUs + rtt/2)`) and maps `ptsUs` through it; with no sample
there is no estimate and capture→receive/capture→enqueue are `-`.

### Audio rules

- Device-wide, session-level (`stream` 0): one mixer tap, not per window.
  Mac → `audio.start {"codecs":[2,3]}` after `welcome`; phone answers one
  AUDIO_CONFIG (chosen codec, Opus preferred) then AUDIO_FRAMEs. Mac →
  `audio.stop` ends it; phone may also send `audio.state {"on":bool,
  "codec":int}` for the UI dot. Unknown codecs are ignored.
- No audio with no windows, and none while all streams are paused. Start on
  the first unpaused `window.open`, stop on the last close/pause.
- One AUDIO_FRAME = exactly one encoder output packet. The first frame after
  CONFIG is decodable without prior state.
- Backpressure: at most ~250 ms of queued audio; older packets are dropped,
  never blocking JSON/video (send-queue priority: JSON > keyframes/config >
  audio > video deltas).
- **Audio overtakes video inside a large frame (R4).** The phone writes audio
  before video deltas and between the fragments of a `VIDEO_CHUNK`ed access
  unit, and keeps at most 16 KiB unsent in the socket (`TCP_NOTSENT_LOWAT`),
  so an audio packet never waits behind more than one 16 KiB fragment. The
  Mac's jitter buffer then sees audio no later than the measured link jitter
  (MEDIA-16/17).

## Session handshake

1. The TLS 1.3 handshake completes with both certificates exchanged and
   verified against the pinned peer (an unpaired phone accepts the Mac's
   certificate and pins it only on a successful pairing; a paired phone
   refuses a Mac whose certificate fingerprint is not the pinned one with
   `{"t":"error","code":"bad_pin"}` and closes — "This phone's identity
   changed" on the Mac side is the same rule in the other direction).
2. Mac → `{"t":"hello","v":4,"clientId":"<uuid>","name":"<Mac name>","id":"<the Mac's identity id>","path":"<8 hex>","codecs":["avc","hevc"],"videoChunks":true}`,
   plus `"pair":true` when the person asked this attempt to pair (a user-driven
   pairing; it then sends `pair.request`). A hello without `pair` is a Mac that
   believes it is already paired. (The planned UDP plane would add
   `"media":["udp"]`; this merge never sends it.) `path` names this connection (its path id,
   8 lowercase hex, unique among the session's live paths) and is on every
   hello. A hello on a **later** connection for the same session also carries
   `"join":"<32 hex>"`, the session id from `welcome` — see "Paths".
   A `v` other than 4 gets `{"t":"error","code":"version","v":4}` and a close:
   `v` is the version that refused, so the Mac can name which app to update
   (see "Versioning").
   `codecs` lists the codecs this Mac decodes in hardware — `"avc"` always and
   `"hevc"` only when `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)` says
   so. A hello without it (an older Mac) means `["avc"]`, so an old Mac never
   gets HEVC. `videoChunks:true` says this Mac reassembles `VIDEO_CHUNK`; a
   hello without it (a Mac before the 2026-11 audio fix) gets whole
   `VIDEO_FRAME`s only.
3. The phone knows the Mac by `clientId` and applies its two connection
   switches before anything else. "Allow connections" off refuses every Mac,
   paired or not, with `{"t":"error","code":"connections_off"}` and a close —
   but only a Mac whose certificate matches a stored pin ever hears that
   message; any other peer is closed without a reply once TLS completes. The
   TLS handshake runs under a 10 s read timeout on a small worker pool, so one
   silent TCP peer never blocks the next connection.
   "Allow new pairings" off refuses an unpaired Mac that asked to pair the
   same way with `{"t":"error","code":"pairing_off"}` before any code exists;
   paired Macs continue, and an unpaired Mac that did not ask to pair is
   closed at once without a reply. If the phone cannot read the switches it
   refuses like `connections_off` (fail closed). Otherwise:
   - **Paired**: its pinned fingerprint must equal the TLS peer's fingerprint;
     then the phone sends `welcome` and the session is ready.
   - **Unpaired, asked to pair**: the phone waits in the pairing phase (next
     section). The Mac asks for the code flow with `{"t":"pair.request"}`; a
     scanned QR is answered by the phone itself with `pair.qr` (see Pairing).
   - **Unpaired, no pairing intent**: the Mac believes it is paired and the
     phone pins nothing for it. The phone answers
     `{"t":"error","code":"not_paired"}` at once and closes, never after its
     handshake timeout.
4. Phone → `{"t":"welcome","session":"<32 hex>","device":{"id":..,"name":..,"model":..,"sdk":36,
   "screen":{"w":1080,"h":2340,"dpi":450},"locked":true,
   "encoder":{"widthAlign":2,"heightAlign":2,"maxWidth":8192,"maxHeight":8192,"maxPixels60":36864000}}}`
   (the planned UDP plane would add `"media":{"udp":<port>,"keyId":"<8 hex>"}`;
   this merge answers no media field, even when the hello offers `udp`).
   `encoder` is the H.264 encoder's own limits, probed once per session: the
   alignment each axis takes, the maximum frame, and the largest pixel count it
   encodes at 60 fps. The Mac asks an app window for its exact backing pixels
   inside these limits and draws them one to one (WIN-5, WIN-52); a stream that
   runs HEVC is fitted to that encoder's own limits too and falls back to H.264
   when the size does not fit. A phone that
   sends no `encoder` (an older build, or an encoder it cannot probe) makes the
   Mac keep its 16 px / 2560 px rule. `session` is this
   session's id: 128 random bits as 32 lowercase hex, a new one for every new
   session, never reused and never derived from a device or peer id; a phone
   answers the id it was asked to join with. The phone allows exactly one
   session at a time:
   - a hello carrying `"join"` for that live session's id, from the live
     session's own pinned Mac, is a **join**: the connection becomes one more
     path of the running session. The session is not dropped, nothing is
     re-paired, and the phone answers `welcome` with the same `session` on it;
   - a hello carrying `"join"` for an id the phone does not serve answers
     `{"t":"error","code":"no_session"}` and closes (the Mac then starts a new
     session); only the live session's own pinned Mac ever hears that code;
   - a second connection without `join` gets
     `{"t":"error","code":"busy","message":"one session at a time"}` and a close —
     unless it is the live session's own pinned Mac (a network drop the phone has
     not noticed yet): the phone drops the stale session, waits for its teardown
     to release the phone's shared state (at most 2 s) and adopts the new
     connection; at the bound it answers `busy`. A different Mac, an unpinned
     peer and a peer that has not authenticated always get `busy`.
   A session has at most 3 paths; a join past that answers
   `{"t":"error","code":"too_many_paths"}` and closes.
5. Every accepted path socket carries TCP keepalive (`SO_KEEPALIVE`,
   `TCP_KEEPIDLE` 20 s, `TCP_KEEPINTVL` 5 s, `TCP_KEEPCNT` 4) and
   `TCP_USER_TIMEOUT` 40 000 ms. A Mac that vanished without a FIN is therefore
   ended by the kernel in about 40 s instead of at the retransmit give-up
   (~15 min), and a healthy Mac is never dropped: its kernel answers the probes
   while the Mac app sleeps. A live session has no app-level read deadline.

Nothing but `hello`, `pair.request`, `pair.nonce` and `pair.ok` is accepted
before `welcome`; anything else is `{"t":"error","code":"protocol"}` and a
close.

## Paths

A **session** is what the person sees; a **path** is one TLS connection carrying
it. A session starts with one path and can grow to three, so a dropped
connection does not end it (`docs/design/paths.md`).

### Reliable and lossy frames

Each direction numbers its **reliable** frames with one `u64` seq per session,
starting at 1:

- reliable, sent wrapped in a `RELIABLE` (`0x30`) frame: `JSON` (`0x01`), `TOUCH`,
  `SCROLL`, `KEY`, `APK_DATA`, `SHARE_DATA`, `DROP_DATA`, `CLIP_DATA`, `FS_DATA`;
- lossy, sent bare: `VIDEO_CONFIG`, `VIDEO_FRAME`, `VIDEO_CHUNK`, `AUDIO_CONFIG`,
  `AUDIO_FRAME`, `HOVER`. They are never replayed, and a new frame type is lossy
  unless it is listed above.

```
RELIABLE (0x30):  len = 18 + n; type 0x30; stream = innerStream
                  payload: u64 seq | u8 innerType | u32 innerStream | n bytes
ACK (0x31):       len = 13;      type 0x31; stream = 0
                  payload: u64 ack      // the next seq this side expects
```

- The ACK is cumulative: every seq below `ack` was received, in order. It is
  sent at most every 10 ms and at least once per 16 received frames, on any live
  path.
- A duplicate (`seq < ack`) is dropped and acked at once. A frame above the next
  expected seq waits in a reorder window of at most 64 frames and 4 MiB; when it
  is full the receiver **stops reading that path** until the gap fills (TCP
  backpressure) — it never drops a frame and never ends the session.
- A receiver acks and drops an unknown `innerType`, so a new message never
  stalls the stream. A `RELIABLE` whose outer `stream` differs from
  `innerStream` is a protocol error.
- The sender keeps unacked reliable frames in a replay buffer of at most
  **16 MiB** per direction, and it is **credit-based**: before reading the next
  chunk of its source a producer checks that the frame fits, and waits for an ACK
  if it does not. So the buffer never overflows, no frame is dropped, and the
  session is never ended for a full buffer. Bulk frames (`APK_DATA`,
  `SHARE_DATA`, `DROP_DATA`, `CLIP_DATA`, `FS_DATA`) may hold at most **12 MiB**,
  which keeps **4 MiB** free so a `JSON`, `TOUCH`, `SCROLL` or `KEY` frame never
  waits behind a file (`docs/design/paths.md` §8).

Example bytes, `ACK` with `ack` 42:

```
00 00 00 0d 31 00 00 00 00 00 00 00 00 00 00 00 2a
```

### The path messages

| t | fields | meaning |
|---|---|---|
| `path.ping` | `path`, `ts` | on that path only, every **2 s**; sent **bare** (not wrapped, not seq'd, not replayed) |
| `path.pong` | `path`, `ts` | the answer, on the same path, at once; RTT is measured with the receiver's own monotonic clock |
| `path.switch` | `path`, `seq` | "my next reliable frame is `seq` and it goes on `path`" |

- `path.ping`/`path.pong` are the only JSON frames that travel bare; they are
  per-path liveness and mean nothing after a switch. A ping with no pong within
  **1.5 s** is one lost sample.
- A **planned** switch is make-before-break: the new path is up and joined, then
  the Mac sends `path.switch` as the last frame on the old path (TCP order means
  everything before it has arrived), then continues on the new one. An
  **unplanned** one sends `path.switch` first on the new path, after the old one
  failed.
- On receiving `path.switch{path, seq}` a side sends its own later frames on
  `path`, and the phone answers with its own `path.switch` marker for its
  direction. The old path is closed once both markers are in, or after 2 s.
- After every switch the Mac sends `window.keyframe` for each open video stream
  (the phone may answer with a fresh `VIDEO_CONFIG` first, as it always may),
  and the phone repeats its current `AUDIO_CONFIG` before its next
  `AUDIO_FRAME` when audio is running.

### Ranking and the switch

Every path, the standby included, is pinged every 2 s; each side keeps RTT
p50/p95 and loss over the last **30 s** and scores a path from those numbers
plus its provider's throughput class (the formula is in
`docs/design/paths.md` §7). Only the **Mac** decides:

- the current path fails (a socket error, or no pong within 1.5 s) → switch at
  once to the best live path;
- another path beats the current one by at least 100 points for **5 s** → switch
  to it;
- a path with fewer than 2 pongs in its window never wins on margin.

### The grace

If no path is usable the session stays live for **30 s** waiting for a join,
replays reliable frames from the peer's last ack when one arrives, and ends at
30 s. The join may arrive on a path of any provider, including one that was
never part of the session before (the phone is published with no session open,
so the next connection can found a new one too). A frame in a `VIDEO_*`, `AUDIO_*` or `HOVER` frame that was in flight is
lost; the keyframe request above repairs the picture.

## Media over UDP

> **WITHDRAWN 2026-11-09.** The native link carries media over TLS/TCP only;
> measurements (ISS-48) showed no case for a UDP plane on the Mac–phone link.
> No peer sends or accepts anything this section describes, and a leftover
> `transport` bench property is ignored. Kept as background for the web client
> (ISS-41, WebRTC) and a later over-the-internet tier. See `docs/design/media-transport.md`.

Video access units can move on an unreliable, unordered datagram plane;
everything else (JSON, input, files, audio and the CONFIG frames) stays on the
reliable path. Audio stays reliable in this phase: it is low-rate and gains
nothing from datagrams once video no longer blocks it. Type 2 is reserved. The design, its threat model and the policy machine are
`docs/design/media-transport.md`; the requirements are PATH-25…PATH-36.

### Capability and keys

- A Mac that has the strategy `auto` or `udp` and speaks it adds
  `"media":["udp"]` to `hello`. A phone that speaks it adds
  `"media":{"udp":<port>,"keyId":"<8 hex>"}` to the **founding** `welcome`,
  only when the hello offered `udp`; a join's welcome does not repeat it (if it
  does, the Mac verifies it is unchanged). Either side missing the field means
  TCP only — no probe, no error.
- Both sides already hold the session's 32-byte TLS exporter
  (`EXPORTER-contigua-pair`: the Mac from BoringSSL's keylog secret and
  `ExporterV2`, the phone from `SSLSockets.exportKeyingMaterial` and
  `TlsExporter`). There is no key-exchange message. Each derives:

```
context = session_id || macPin || phonePin || "EXPORTER-contigua-pair"
c2s = HKDF-SHA256(ikm = pairingExporter, salt = context,
                  info = "contigua-media-c2s", 32)
s2c = HKDF-SHA256(ikm = pairingExporter, salt = context,
                  info = "contigua-media-s2c", 32)
keyId = lowercase hex of SHA-256(c2s || s2c)[0..4]
```

  `macPin` and `phonePin` are the 32-byte SPKI SHA-256 fingerprints in that
  order. The phone opens Mac→phone datagrams with `c2s` and seals phone→Mac
  with `s2c`; the Mac does the reverse. A `keyId` in `welcome` that differs
  from the Mac's own derivation means the exporters disagree: it sends no
  probe and stays on TCP. The exporter is the founding path's and stays with
  the session; a path switch does not change it. Keys last for the session
  and are discarded with it; the key buffers are zeroed, and no key byte is
  ever logged or written to a file (no `SSLKEYLOGFILE`).

### The datagram

One UDP datagram is one fragment, at most **1200 bytes** (never IP-fragmented):

```
outer (plaintext, the AEAD associated data)                         18 bytes
  u8  magic = 0x50
  u8  version = 1
  u32 keyId
  u16 epoch            // first UDP media epoch is 1, +1 per switch
  u64 seq              // per direction for the whole session: starts at 1, never
                       // resets on an epoch switch, one space for every type
  u16 ciphertextLen    // inner header + payload + 16-byte tag
ciphertext (AES-256-GCM, 96-bit nonce = 00000000 || u64 seq)
  u8  type             // 1 video, 2 audio (reserved), 3 feedback, 4 nack, 5 probe, 6 probe reply, 7 parity
  u8  flags            // bit0 keyframe, bit1 retransmit
  u32 stream
  u32 frameId          // per stream, increments for every access unit
  u64 ptsUs            // the access unit's pts; 0 for control packets
  u16 fragmentIndex
  u16 fragmentCount
  u32 sendUs           // the sender's monotonic µs, low 32 bits
  u8  payload[]        // the access unit's bytes (Annex-B for video, packet for audio)
```

The inner header is 26 bytes; with the 18-byte outer header and the 16-byte tag
one fragment carries at most **1140 bytes** of an access unit. A packet bigger
than 1200 bytes, with another magic/version/keyId, an old epoch, a failed tag or
a sequence outside the 1024-packet replay window is dropped silently. The tag is
verified **before** the replay window advances: a tampered high sequence must
not move the window and make valid packets look old. A NACK resend is the
identical datagram (same sequence and ciphertext) or a fresh sequence; it is
never re-sealed under the old sequence.

Example outer header for a 46-byte ciphertext (probe, epoch 1, seq 1, keyId 1):

```
50 01 00 00 00 01 00 01 00 00 00 00 00 00 00 01 00 2e
```

### Payloads

| type | direction | payload |
|---|---|---|
| 1 VIDEO | phone→mac | Annex-B bytes of one access unit; the receiver rebuilds `VIDEO_FRAME` (`ptsUs`, flags, bytes) |
| 2 AUDIO | — | reserved; audio stays on the reliable path in this phase |
| 3 FEEDBACK | mac→phone | `u64 highestSeq · u32 received · u32 lost · u32 rttMs · i32 owdTrendUsPerS · u32 owdP95Us (relative to the session minimum) · u32 queueAgeMs` (32 bytes, every 100 ms) |
| 4 NACK | receiver→sender | `u16 count` then `count` × `u64 seq` (count ≤ 32, at most 200/s) |
| 5 PROBE | mac→phone | `u32 nonce` |
| 6 PROBE REPLY | phone→mac | the same `u32 nonce`; authenticated, never larger than the probe |
| 7 PARITY | sender→receiver | `u64 firstSeq · u16 count` then the XOR bytes covering `count` consecutive data packets from `firstSeq`; at most one per 10 data packets, `stream.fec=parity` only |

- A frame is reassembled by `(epoch, stream, frameId)` from any fragment order.
  An incomplete delta is dropped **100 ms** after its first fragment; an
  incomplete keyframe gets **1 s**, because its bits can take that long at the
  target rate. The display never waits for it; there is no jitter buffer.
- A dropped non-key frame triggers the existing `window.keyframe` request
  path, at most one per stream per 500 ms; an incomplete keyframe is NACKed
  first.
- NACK, feedback and probes share the one per-direction sequence space, so the
  replay window protects every packet type.

### The switch

| t | fields | meaning |
|---|---|---|
| `media.switch` | `to`: `udp`/`tcp`, `epoch` | the Mac's decision, reliable (JSON priority) |
| `media.switch.ack` | `epoch` | the phone stops the old plane here |
| `media.epoch` | `epoch` | on the way back to TCP: the epoch of the TCP video that follows |

1. The Mac sends `media.switch{to:udp,epoch:N}` after the probe passes. The
   phone acks, stops TCP **video** at the ack (audio is on TCP and unaffected),
   and sends a fresh IDR on UDP in epoch `N`; the Mac shows the last TCP picture until that keyframe is
   complete, then ignores TCP video. Config is unchanged.
2. The Mac sends `media.switch{to:tcp,epoch:N}` on a failure. The phone acks,
   sends `media.epoch{N}` on the reliable path, then a TCP keyframe; the Mac
   ignores older-epoch UDP packets. One IDR per switch, never a replay, never
   a second `window.keyframe` for the same switch.
3. The first UDP media epoch is 1. A switch that does not produce its keyframe
   within 2 s is cancelled with one more `media.switch`.

### Limits and failure

- One access unit is at most 8 MiB (the existing frame cap), so at most 7359
  fragments; more is a dropped frame, not a closed session.
- Reassembly holds at most 2 MiB per session and 1 MiB per stream; the UDP
  socket is one per session; the send buffer is 1 MiB.
- UDP never ends a session and never delays reliable frames. Any failure
  returns media to TCP with one keyframe; the phone's slot, the pins and the
  path machine are unchanged.
- The phone answers at most 100 probes per second per source, and only after
  the datagram authenticates.

### Browser mapping

The inner header and payload are the browser's unit: a WebTransport client
sends them as datagrams (WebTransport supplies the security, so the 18-byte
outer header and GCM tag are omitted), and a WebRTC client sends the same bytes
on a data channel with `ordered:false, maxRetransmits:0`. RTP is not used; it
would add a second packetization and its own jitter buffer. No browser client
is built in this epic.

## Direct link

Only a build compiled with the direct provider offers this
(`docs/design/direct-link.md`); a public build never dials it and never sends
these messages. The path itself is ordinary: one more TLS connection, pinned the
same way, ranked like any other. The phone publishes the Wi-Fi Aware service
`_contigua-nan._tcp` and listens on the Aware network; the Mac dials it.

| t | dir | fields | meaning |
|---|---|---|---|
| `direct.enable` | mac→phone | `on` | this Mac's switch for this phone; sent at `welcome` and on change, and **stored** by the phone (so `on: false` keeps it from being published for even with no session open). The phone publishes and keeps a standby only while it is on, its own switch is on, its permission is granted and it holds a key |
| `direct.key` | mac→phone | `key` (64 hex) | the data-path key for the Wi-Fi Aware data path, 32 random bytes; sent once, inside TLS, on the first LAN session in which both switches are on |
| `direct.key.ok` | phone→mac | — | the key is stored; an unacknowledged key is regenerated on the next LAN session |
| `direct.state` | phone→mac | `on`, `reason`? | the phone's switch and permission state; `reason` is `no_permission`, `no_feature`, `location_off` or `aware_busy` |

- The key is never logged on either side, and its only wire form is this
  message. It is used as the Wi-Fi Aware data path's passphrase (base64 of the
  32 bytes) and for the service-specific info the phone publishes:
  `HMAC-SHA256(key, "pd-nan-v1" ‖ u64_be(window))[0..8]` for a 10-minute window,
  which is all the air carries — no device id, name, model or fingerprint.

## Pairing (first contact)

Numeric comparison (Bluetooth SSP style) over the TLS channel: both screens show
the same 6-digit code and the person taps Allow on the phone. Nothing is typed
and no field ever carries the code; comparing the screens authenticates the
channel against a man in the middle (docs/design/e2ee.md §4).

### Code flow

1. Mac → `{"t":"pair.request"}`.
2. Phone → `{"t":"pair.commit","c":"<64 hex>"}` where
   `c = SHA-256("pd-commit-v2" || Np || phoneFP || macFP)`, `Np` = 16 fresh
   random bytes the phone keeps secret for now, and the fingerprints are the
   two certificate point fingerprints.
3. Mac → `{"t":"pair.nonce","n":"<32 hex>"}` with `Nm` = 16 fresh random bytes.
   The Mac releases `Nm` only after the commit is on record, so the phone's
   `Np` is hash-locked before the Mac's nonce exists.
4. Phone → `{"t":"pair.reveal","n":"<32 hex>"}` with `Np`. The Mac recomputes
   the commit from the revealed `Np` and both fingerprints; a mismatch, or a
   reveal without a verified commit, closes with `{"t":"error","code":"pair_commit"}`.
5. Both sides derive the code (docs/design/e2ee.md §4/§4b):

```
exporter = TLS-Exporter("EXPORTER-contigua-pair", empty context, 32 bytes)
code     = uint64_be(SHA-256("pd-code-v2" || exporter || macFP || phoneFP
                             || Nm || Np)[0..8]) mod 1_000_000   // "123 456"
```

   If the phone has no exporter, it sends `{"t":"error","code":"pair_exporter"}`
   and closes before revealing `Np` or showing a code; it never fills the
   exporter with zeros. (The exporter call is API 31+, so an Android 11 phone
   fails closed here rather than throwing `NoSuchMethodError`.)

   The phone shows it with its Allow/Deny prompt ("Pair with <Mac name>?"), the
   Mac shows it next to the phone row.
6. The person compares the screens and taps **Allow** or **Deny** on the phone.
   - Allow: the phone pins the Mac's fingerprint, replies
     `{"t":"pair.ok","phoneFP":"<64 hex>","macFP":"<64 hex>"}` (what each side
     pins) and immediately follows with `welcome`.
   - Deny: `{"t":"error","code":"pair_denied"}`, then the phone closes.
   - No decision within **120 s**: `{"t":"error","code":"pair_timeout"}`, then
     the phone closes. Within the pairing phase the phone applies no read
     timeout; the 120 s decision window is the only limit.
7. If the Mac closes first (Cancel, network loss), the phone discards the
   request and dismisses its prompt. One pairing request per session; a second
   `pair.request` is ignored. After a **Deny** or a **120 s timeout** the phone
   refuses a new `pair.request` from an unpaired Mac for **30 s** with
   `{"t":"error","code":"pair_cooldown"}` and a close, so a LAN peer cannot make
   the phone prompt again in a loop; the Mac's sheet says "Wait a moment, then
   try again." for it, distinct from a fresh denial (`pair_denied`). A scanned QR is still honoured: it needs
   the person to scan the Mac's screen.

### QR flow (Mac shows, phone scans)

The Mac shows `contigua://pair?c=<clientId>&n=<name>&f=<macFP hex 64>&s=<S hex 32>`,
where `s` is a one-time 128-bit secret that expires with the QR and is consumed
the first time the phone answers with `pair.qr` (a second hello in that window
gets no `pair.qr`). The phone scans it, pins `f` (the Mac fingerprint), and
proves `s` inside the TLS session:

1. Mac opens the QR sheet: it probes the phones it can reach (and the
   `--connect` target) with a pairing-channel `hello`, carrying no code.
2. Phone (holding a scanned payload whose `f` equals the TLS peer's
   fingerprint) → `{"t":"pair.qr","m":"<64 hex>"}` where
   `m = HMAC-SHA256(S, "pd-qr-v2" || exporter || phoneFP)`.
3. Mac verifies `m` with the sheet's secret and answers
   `{"t":"pair.ok","phoneFP":"<64 hex>","macFP":"<64 hex>"}`; the phone's Allow
   prompt still gates completion, and the phone then pins the Mac and sends
   `welcome`.
4. An expired or unknown QR secret is refused like any failed pairing; the
   Mac's sheet closes on `welcome`.

## JSON messages

Mac → phone (after `welcome`):

| t | fields | meaning |
|---|---|---|
| `ping` | `ts`, `monoUs`? | phone replies `pong` with same `ts` and its own `now`; `monoUs` is the Mac's CLOCK_MONOTONIC µs for this ping, the base the pong's `now` is compared on (optional, an older phone ignores it) |
| `stream.stats` | `on`: bool | session-wide switch: while on, every unpaused streaming window sends `stream.stats` every 2 s; off sends none; see "Stream stats" |
| `path.ping` | `path`, `ts` | a path's own liveness probe, sent bare on that path every 2 s; see "Paths" |
| `path.pong` | `path`, `ts` | the answer, on the same path; either side sends it |
| `path.switch` | `path`, `seq` | "my next reliable frame is `seq` and it goes on `path`"; see "Paths" |
| `direct.enable` | `on` | this Mac's direct-link switch for this phone (direct builds); the phone publishes only while it is on; see "Direct link" |
| `direct.key` | `key` | the Wi-Fi Aware data-path key, 64 hex, sent inside TLS once; see "Direct link" |
| `apps.list` | — | phone replies `apps` |
| `apps.icon` | `pkg`, optional `px` | phone replies `icon` (with `fg`/`bg`/`mono` layers when the icon is adaptive); `px` is the pixel side of the 108 dp layer it should render (default 216, clamped to 216…1296), an older phone ignores it |
| `window.open` | `stream`, `w`, `h`, `dpi`, and `pkg` (+ optional `activity`) **or** `"mode":"phone"`, and `newInstance` (optional bool) | create VD + encoder, launch app on it; `mode: phone` mirrors display 0 instead (`window.opened` has `displayId` 0 and the frame's size, the codec's nearest size to the screen's aspect inside `w`×`h`, with the screen's picture in it as `window.content` says; a rotation sends a new VIDEO_CONFIG with the turned size; error `mirror_unavailable` if the phone can't). `newInstance: true` asks for another task of the app on this display: the phone adds `FLAG_ACTIVITY_NEW_DOCUMENT \| FLAG_ACTIVITY_MULTIPLE_TASK` to the launch Intent, so the activity's own `launchMode`/`documentLaunchMode` still decides whether a second task appears; past the phone's cap it answers error `too_many_windows` before a display exists (see "Several windows of one app") |
| `window.adopt` | `stream`, `taskId`, `w`, `h`, `dpi` | create a display for a task the app started itself, like `window.open`, and move that task onto it with `startActivityFromRecents` (`setLaunchDisplayId` + fullscreen; permission `START_TASKS_FROM_RECENTS`). `window.opened` answers as for any stream, with the adopted task's `taskId` and `started: "moved"`; a refusal or a task that is gone answers `error cannot_adopt` and leaves the task where it was (never a relaunch). See "Several windows of one app" |
| `window.resize` | `stream`, `w`, `h`, `dpi` | resize VD + reconfigure encoder; phone sends new VIDEO_CONFIG, then `window.resize.ack`. A request equal to what the display already shows is a no-op; the same size at a new dpi changes the display's density and rebuilds no encoder (so no new VIDEO_CONFIG); one the phone cannot apply answers `refused` |
| `window.close` | `stream` | tear down that VD/encoder, and with it that display's task: a task that still exists after the display went — running, or only a card in the phone's Recents — is removed by id, so a closed window leaves no card behind; its app's other tasks and the session stay up. It is the last message the Mac sends for that stream: anything later is answered `error no_stream` (the Mac gates it out, WIN-38) |
| `window.pause` | `stream` | Mac window hidden/minimized/occluded: stop encoding (keep VD + app alive) |
| `window.resume` | `stream` | resume; phone sends CONFIG + keyframe |
| `window.keyframe` | `stream` | request IDR (decoder error recovery) |
| `window.quality` | `stream`, `bitrate` (bps, optional), `maxFps` (optional) | live encoder quality; optional, the phone may ignore it |
| `link.open` | `stream`, `w`, `h`, `dpi`, `url` | like `window.open`, but the phone starts `ACTION_VIEW` for `url` on the new display and Android picks the app; see "Links" |
| `window.launch` | `stream`, `pkg` (+`activity`) | launch an app onto an existing window's display (phone mode) |
| `task.continue` | `stream`, `w`, `h`, `dpi` | "Open <App> on Mac" (docs/design/handoff.md): open a virtual display for [stream] like `window.open` and move the app that is in the foreground on the phone's own screen onto it, keeping the task. On success `window.opened` (see below) with `"started":"moved"`; when the move is refused the package is relaunched on the display instead and `started` is `"fresh"`; when nothing continuable runs in the foreground the phone answers `error code nothing_to_continue` and opens nothing |
| `task.front` | `seq` | a one-shot read of the app in front on the phone's own screen (display 0), for the panel's "Open <App> on Mac" row (docs/design/handoff.md). The phone answers `task.front` with the same `seq` and `pkg` (the package) or `pkg: null` when nothing continuable is in front (our app, the launcher/home or SystemUI); it opens nothing, sends no HOME key and keeps no watch. `error code not_available` when the phone cannot read its task list. The Mac asks only while the card is open, at most once every 2 s, and ignores a reply whose `seq` is not its newest request |
| `nav` | `stream`, `action`: `back`/`home`/`recents` | back = KEYCODE_BACK on that display; home/recents (HOME / APP_SWITCH on display 0) only in phone mode |
| `text` | `stream`, `text` | type text into the focused field of that display |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
| `clip.enable` | `on` | the Mac's clipboard switch for the background sync: while it is off the phone sends and applies no `clip.set` or unprompted `clip.image.*`; a `clip.image.start` with `paste:true` still applies (a person's ⌘V); see "Clipboard sync" |
| `apk.install` | `id`, `files`: `[{"name","size","sha256"}]` | start an APK install; `APK_DATA` frames follow; see "APK install" |
| `apk.cancel` | `id` | abandon that install |
| `drop.start` | `id`, `name`, `mime`, `size`, `sha256`, optional `resume`, optional `target`, optional `index`, optional `count` | start a file drop (a Finder drag onto a phone window); `DROP_DATA` frames follow; `target` is the package of the window's app, so the finished batch is shared straight to it; `index`/`count` place this file in one gesture's batch; see "Drop Mac → phone" |
| `drop.cancel` | `id` | abandon that drop |
| `clip.image.start` | `id`, `mime`, `size`, optional `paste` | a clipboard image follows in `CLIP_DATA` frames; `paste:true` is a person's own ⌘V in a window and bypasses `clip.enable`; see "Clipboard images" |
| `clip.image.end` | `id`, `size`, `sha256` | the image is complete |
| `clip.image.abort` | `id` | the sender gave up; discard what arrived |
| `audio.start` | `codecs` (array of int, e.g. `[2,3]`) | start device-wide audio; phone answers AUDIO_CONFIG + frames |
| `audio.stop` | — | stop device-wide audio |
| `phone.ring` | `seconds`? | ring the phone (app process, alarm over the lock screen, ≤ 30 s); see "Ring" |
| `phone.ring.stop` | — | stop a running ring |
| `phone.dnd` | `mode`: `priority`/`alarms`/`none`/`off` | set the phone's Do Not Disturb (its zen mode) for a Mac Focus or a manual set; see "Focus and Do Not Disturb" |
| `phone.ringer` | `mode`: `normal`/`vibrate`/`silent` | set the phone's ringer mode (never a volume); see "Ringer" |
| `phone.volume` | `level`: int | set the phone's music volume (STREAM_MUSIC), clamped to its maximum; see "Volume" |
| `phone.wake` | — | wake the phone's own screen (display 0) without unlocking it; see "Phone screen" |
| `phone.panel` | `off`: bool, `ignorePower`?: bool | hold the mirrored panel off while the phone window keeps rendering, or give it back (`off: false`); `ignorePower` says a power press does not end the hold; see "Phone screen" |
| `fs.list` | `id`, `path`, `page`? | children of `path`; `page` is the phone's opaque cursor, absent = first |
| `fs.stat` | `id`, `path` | one item's metadata |
| `fs.digest` | `id`, `paths`: up to 64 folder paths | one reply with each folder's digest; see "Phone files" |
| `fs.read` | `id`, `path`, `offset`, `length`, `etag`? | stream `length` bytes from `offset` (`FS_DATA`, then `fs.read.end`); an `etag` that no longer matches answers `fs_stale` |
| `fs.cancel` | `id` | abandon a running `fs.read`; the phone stops streaming and drops what is queued |
| `ui.tree` | `stream`, `seq`, `offscreen`? (**wire change, #171 B6**) | read that window's display's accessibility tree; see "UI tree" |
| `ui.settle` | `stream`, `seq`, `quietMs`, `timeoutMs` | **wire change (#171 B1):** answer when the display's content stops changing for `quietMs` with nothing loading, or at `timeoutMs`; see "UI tree" §7 |
| `ui.press` | `stream`, `seq`, `k`, `holdMs`?, `expect`? | **wire change (#171 B3):** press the node whose key `k` the latest read named, at its bounds now; see "UI tree" §8 |
| `ui.type` | `stream`, `seq`, `text`, `clear`?, `submit`? | **wire change (#171 B5):** type into the focused field of that display as keys or by setting its text, never through the clipboard; see "UI tree" §10 |

Phone → Mac:

| t | fields |
|---|---|
| `pong` | `ts`, `now` | `ts` echoes the ping; `now` is the phone's CLOCK_MONOTONIC µs, the same clock and unit as VIDEO_FRAME's `ptsUs` (absent on an older phone, then the Mac has no clock estimate) |
| `path.ping` | `path`, `ts` | the same probe from the phone's side |
| `path.pong` | `path`, `ts` | its answer |
| `path.switch` | `path`, `seq` | the phone's own marker when the Mac switches the session ("Paths") |
| `direct.key.ok` | — | the key in `direct.key` is stored ("Direct link") |
| `direct.state` | `on`, `reason`? | the phone's direct-link switch and permission state; `reason` is `no_permission`, `no_feature`, `location_off` or `aware_busy` |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
| `apps` | `apps`: `[{"pkg","label","activity","multi"}]` — launchable activities, sorted by label; `multi` says whether a second instance can run (WIN-24): the launcher activity declares `android.window.PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI` (read per component with `PackageManager.getProperty`, API 35+, false on older phones) **and** its `launchMode` is not `singleTask`/`singleInstance` **and** its `documentLaunchMode` is not `never`; an allow-list covers apps found to work without the property (empty today) |
| `icon` | `pkg`, `png` (base64, 96×96 px, or 2/3 of `px` when the request had one); for an adaptive icon also the whole 108 dp layers as base64 PNGs at the requested `px` (216×216 px by default): `fg`, `bg` and, when present (API 33+), `mono` — optional, so an old Mac ignores them. Mac ▸ docs/design/dock.md §Icons for how the icons are drawn |
| `window.opened` | `stream`, `displayId`, `w`, `h`, `taskId` — the task the display shows (0 for the Phone Mirror, which has none, or when the phone could not read its task list); `started`: `"moved"` (default; the task the display shows was moved to it, state kept — the normal answer to `window.open` and the only answer to a successful `window.adopt`) or `"fresh"` (the phone couldn't move the task and relaunched the same package; the app's state may be lost; never sent for `window.adopt`) |
| `window.task` | `stream`, `taskId`, `pkg`, `label` — the app started a task of its own while one of its apps was streamed (WIN-44): the new task's id, its package and its own label. Sent once per task, at most once a second per package, only for a fresh `onTaskCreated` that the phone itself did not launch or move; the only other stream message is `window.title`'s app/pkgs (WIN-48). `label` is phone content: never logged, never used as a file name. The Mac decides with the New-item rule and answers with `window.adopt` (WIN-45) |
| `window.closed` | `stream`, `reason` (`requested`/`app_exited`/`moved_to_phone`/`error`) — `moved_to_phone` is the person opening the streamed app on the phone's own screen: the display's task (same id) changed display and left the streamed display empty (WIN-49); `app_exited` stays for `onTaskRemoved` or a real exit |
| `window.resize.ack` | `stream`, `w`, `h`, `dpi` (the request echoed), `outcome`: `"resized"` (new size, new encoder), `"density"` (same size, new dpi, no encoder rebuild), `"same"` (the display already showed it) or `"kept"` (the encoder refused; the stream keeps its old size) or `"refused"` (the phone cannot apply it: no such stream, or a size of zero). Every `window.resize` is answered with one, the early returns included; the Mac keeps one resize in flight and sends the newest waiting value when this arrives, or when the stall limit passes without one |
| `stream.stats` | `stream`, `windowMs`, `codec`, `frames`, `kf`, `keyIdr`, `keyNotIdr`, `kfReq`, `bytes`, `drop`, `dropEp`, `dropGapMs`, `skip`, `susp`, `suspMs`, `refine`, `targetBps`, optional `encP50`/`encP95`/`queueP50`/`queueP95` (µs), `qpP50`/`qpP95`/`qpAvg` (average QP), `retrans`/`rto`/`lost_retrans` (system-wide TCP counter deltas), optional `noFrame` (one no-frame episode state, see "Stream stats") — the stream's counters over the last `windowMs` (2 s since the previous message); optional fields are absent when there is no measurement; see "Stream stats" |
| `window.still` | `stream` — the stream is live but its encoder has produced no output buffer for 1000 ms; sent again once a second while the silence lasts. A heartbeat for the Mac's picture rule (WIN-17), never a first frame; see "Video rules" |
| `window.title` | `stream`, `label`, `pkg` — the display's task and its app: `pkg` is the task's own app (the root's package from `baseActivity`, then `baseIntent.component`), and only a task that reports no root falls back to its top activity, then `topActivityInfo`; another package's activity on top of the task never becomes the app (WIN-28). Every stream sends it at once when that app changes (`label` is the app's label, `pkg` its package). An app or link stream also carries `title`: the task's own description (`RecentTaskInfo.taskDescription.label`), or the app's label while the phone describes none. A change to `title` alone goes out at most once a second (the newest label always goes out); a message whose `label`/`pkg` changed carries the current `title` and counts as that send. The Mac titles a window with `title` while the app has several windows, and takes a link or handoff window's Dock identity from `pkg` |
| `task.front` | `seq` (the request echoed), `pkg`: string or null — the app in front on the phone's own screen when the Mac asked (docs/design/handoff.md); `null` when nothing continuable is in front. A read: it opens nothing and changes nothing on the phone, and the phone never sends it unasked |
| `state` | `locked`: bool, `battery`: int, `charging`: bool, `dnd`: `"off"`/`"priority"`/`"alarms"`/`"none"`, `ringer`: `"normal"`/`"vibrate"`/`"silent"`, `volume`: int, `volumeMax`: int, `screen`: `"on"`/`"off"`, `secure`: bool, `panel`: `"on"`/`"off"`, `maxWindows`: int (the most app windows this phone allows at once; 4 today), `lockSource`: `"keyguard_listener"`/`"broadcast"`/`"app_relay"`/`"initial_read"` (**wire change, #171**: which source gave the current `locked`: the hidden window-manager keyguard listener, the screen broadcasts, the app process's relay, or the read at start that no event has replaced since; a change of source alone is a change) — sent on change; `dnd`/`ringer` are absent on a phone that does not support them (old builds), `volume`/`volumeMax` are both absent on one that cannot read its music stream, `secure` while no phone window is open; see "Phone screen", "Volume" and "Secure screens" |
| `audio.state` | `on`: bool, `codec`: int — audio capture on/off (for the UI dot) |
| `ring.state` | `ringing`: bool — a `phone.ring` started (`true`) or ended (`false`) |
| `power.locked` | — **no longer sent** (#142): app windows run in a display group of their own, so a power press never stops their picture. A Mac still accepts it and holds each app window's last frame for a short grace; see "Phone screen" |
| `error` | `code`, `message`, optional `stream` |
| `apk.progress` | `id`, `bytes` — bytes written into the install so far |
| `apk.result` | `id`, `ok`; success: `pkg`, `label`, `version`; failure: `code`, `message` |
| `share.text` | `text` — shared from an Android app; see "Share phone → Mac" |
| `share.file` | `id`, `name`, `mime` — a shared file follows in `SHARE_DATA` frames |
| `share.end` | `id`, `size`, `sha256` — the file is complete |
| `share.abort` | `id` — the phone gave up on that file; the Mac discards it |
| `drop.progress` | `id`, `bytes` — bytes written of a file drop |
| `drop.result` | `id`, `ok`; success: `path`; failure: `code`, `message` |
| `clip.image.start` | `id`, `mime`, `size`, `paste`? — sent by either side; `paste:true` only by the Mac |
| `clip.image.done` | `id`, `ok` — the phone finished a Mac image: `ok:true` means the bytes verified and its clipboard holds the image, and only then may a paste follow; `ok:false` means it was refused (see "Clipboard images") |
| `fs.items` | `id`, `page` (null = last), `items`: `[{"name","dir","size","mtime","ino","etag"}]` — no path per item; the parent is implicit |
| `fs.item` | `id`, `item` (same shape) |
| `fs.read.end` | `id`, `size`, `sha256` — the requested range is complete and correct |
| `ui.tree` | `stream`, `seq`, `ok`; success: the tree of "UI tree" §2 (as #162 leaves it) plus #171's `loading`, `omitted` and row fields (§9); failure: `code`, `message` — see "UI tree" |
| `ui.settle` | `stream`, `seq`, `ok`; success: `settled`, `waitedMs`, `events`, `reason`?; failure: `code`, `message` — **wire change (#171 B1)**, see "UI tree" §7 |
| `ui.press` | `stream`, `seq`, `ok`; success: `box`, `at`, `role`, `text`?, `desc`?; failure: `code`, `message`, `coveredBy`?, `now`? — **wire change (#171 B3)**, see "UI tree" §8 |
| `ui.type` | `stream`, `seq`, `ok`; success: `entry`, `via`, `characters`; failure: `code`, `message` — **wire change (#171 B5)**, see "UI tree" §10 |

Unknown `t` values and unknown binary frame types are ignored (log once). Unknown
fields are ignored. `activity` is a component string `pkg/fully.qualified.Class`.
The phone sends one `state` right after `welcome`, then on change.

### Several windows of one app

One app on one phone can run in several windows, one per task, when the Mac asks
for another (`window.open` with `newInstance`, or a click on the New Window
command). The Mac's only evidence that an app can do it is `apps.multi`, and the
phone counts the windows it will run. The evidence for what the platform allows
and what a window costs came from a spike that is not in the repo.

- One stream is one virtual display and one task. `newInstance` never reuses an
  existing task; without it the phone launches with `FLAG_ACTIVITY_NEW_TASK` and
  the platform may move the app's one task to the new display.
- `window.opened.taskId` is the phone's own task id for the display; it is not
  stable across a reconnect, and the Mac keeps it only to name and close the right
  window. It is read after the launch (which is what makes the task), so video
  that arrives before `window.opened` is held: its CONFIG and its keyframe go out
  after the reply, and delta frames that would precede them are dropped.
- `window.title` always says which app the display shows (`label`, `pkg`), the
  moment it changes: a link window's Dock identity and a handoff window's re-open
  come from `pkg`. On an app or link stream the same message carries `title`, the
  task's label, falling back to the app's label while the phone describes none. A
  change to `title` alone waits out the second (at most once a second; the newest
  label always goes out, a label that settles just after a send is not dropped),
  while a new app on top goes at once and its `title` counts as that send.
- `maxWindows` is per phone and counts app streams only; the Phone Mirror is a
  separate encoder and is not counted, and neither is a stream that has not named
  its content yet. Past it, `window.open` (with or without `newInstance`) answers
  `too_many_windows` before creating a display.
- Closing a window ends only that display's task. The display's
  `FLAG_DESTROY_CONTENT_ON_REMOVAL` usually takes the task with it; a task that
  outlives its display is removed by id, and a task another window of the session
  still shows is never removed. The app is never stopped, so its other windows
  and the session keep running.
- An app may start another task of its own — a browser's "New window" — while
  one of its apps is streamed. The phone registers
  `ITaskStackListener.onTaskCreated` (`MANAGE_ACTIVITY_TASKS`) and reports a
  fresh task id whose package has an open app stream, unless the phone itself
  launched it (`window.open`, `window.launch`) or moved it (`task.continue`,
  `window.adopt`): `{"t":"window.task","stream":N,"taskId":214,"pkg":"…","label":"…"}`.
  The report never moves the task; the Mac decides with the same New-item rule
  as ⌘N and sends `window.adopt` when it may act. An event for a task the phone
  did not create is not a report: the person's Home, launcher and Recents never
  produce a fresh id on the fixtures measured (WIN-48).
- `window.adopt` creates the display first, then calls
  `IActivityTaskManager.startActivityFromRecents(taskId, options)` with
  `ActivityOptions.setLaunchDisplayId(displayId)` and the hidden fullscreen
  windowing mode (the call `moveRootTaskToDisplay` cannot make for a task that
  is a split child; see `docs/research/in-stream-window.md`). The move is
  verified against the task list: only a task now on the new display answers
  `window.opened started: "moved"`; anything else answers `error cannot_adopt`,
  closes the display and leaves the task where it was.
- When the person opens the streamed app on the phone's own screen, its task
  keeps its id and changes display; the streamed display is left empty. The
  phone closes that stream with `window.closed reason: "moved_to_phone"`, not
  `app_exited`, and reports no task.

## Clipboard sync

Plain text only, in both directions, while a session is ready
(`{"t":"clip.set","text":"..."}`, sent by either side):

- A side sends `clip.set` when its clipboard changes after `welcome`. The text
  present at `welcome` is not sent.
- `text` is UTF-8 and at most 1 MiB (1 048 576 bytes). Larger text is not sent;
  a receiver ignores a `clip.set` that is larger.
- Empty text is not sent.
- Each side keeps the SHA-256 of the text it last sent or received. A change
  whose text has that hash is not sent, so received text is never echoed back.
  On receiving `clip.set` a side records the hash first and then writes the
  text, so the change that write causes is not echoed back.
- The Mac skips pasteboard items marked as secret by password managers
  (`org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`), and
  the phone skips a clip its system marks sensitive
  (`ClipDescription.EXTRA_IS_SENSITIVE`, `android.content.extra.IS_SENSITIVE`).
- The Mac's "Share clipboard with your phone" is the only switch, and it is
  off on a fresh profile. The Mac sends `{"t":"clip.enable","on":bool}` at
  every `welcome` and whenever the person changes it; the phone starts with
  sync off, so a phone that is not told sends nothing. While it is off that
  side neither sends nor applies `clip.set` or a background clipboard image —
  the bytes stay on the phone, and the Mac's own side reads the setting for
  its sends and its applies. The exception is a person's own ⌘V in a window:
  a `clip.image.start` with `"paste":true` is explicit like a drop and the
  phone applies it even while the switch is off (SHARE-16).
- A pasteboard item that carries `public.file-url` is a file copy, not text:
  its text is the file's name and is never sent as `clip.set`. The Mac sends a
  file copy of exactly one image file at or under 8 MiB as a clipboard image;
  any other file copy (not an image, several files, over the cap, unreadable)
  sends nothing (docs/specs/share-clipboard.md SHARE-2).

## Links

`{"t":"link.open","stream":N,"w":..,"h":..,"dpi":..,"url":"https://example.com"}` opens a
link from the Mac in a new window. The replies are those of `window.open`
(`window.opened`, VIDEO_CONFIG, frames, `window.title`, `window.closed`).

- `url` is UTF-8, at most 8 KiB (8192 bytes) after trimming surrounding whitespace, and
  contains no whitespace or control characters.
- Allowed schemes (case-insensitive): `http`, `https` (both need a host), `geo`, `tel`,
  `mailto`. Every other scheme (`intent:`, `file:`, `content:`, `javascript:` …) is refused.
- Both sides validate. The phone refuses an invalid `url` with
  `{"t":"error","code":"bad_url","stream":N}` and creates no display.
- The phone starts `ACTION_VIEW` with `CATEGORY_BROWSABLE` on the new display, so
  verified app links open their app and other web links the default browser. No
  handler → `launch_failed` (the window stays open, like a failed app launch).

## APK install

Installs an app sent from the Mac (docs/design/apk.md). One install at a time.

1. Mac → `{"t":"apk.install","id":N,"files":[{"name":"base.apk","size":..,"sha256":"<64 hex>"},…]}`.
   `id` is a u32 ≠ 0 chosen by the Mac. `name` matches `[A-Za-z0-9._-]{1,100}`, ends in
   `.apk` and is unique; at most 64 files, at most 1 GiB (1 073 741 824 bytes) in total.
2. Mac → `APK_DATA` frames with `stream` = `id`: the files' bytes back to back, in the order
   listed, each frame ≤ 1 MiB. The phone drops frames for any other `id`.
3. Phone → `apk.progress` (at most 4 per second, and once with every byte received), then
   exactly one `apk.result`. Success: `{"ok":true,"pkg","label","version"}`. Failure:
   `{"ok":false,"code","message"}` where `code` is the package manager's own
   `INSTALL_FAILED_*` / `INSTALL_PARSE_FAILED_*` token or one of `bad_request`, `too_large`,
   `busy`, `checksum` (a file's SHA-256 differs; nothing is committed), `cancelled`, `failed`.
4. Mac → `apk.cancel` at any time; the phone abandons the install and replies
   `apk.result` with `code` `cancelled`. A session that ends abandons its install.

The phone streams each file into a package-manager session and commits only after every
file arrived with its SHA-256; it stores no copy of its own.

## Share phone → Mac

What a person shares from an Android app with **Send to Mac** (docs/design/sharein.md).
Only the phone sends these; the Mac never answers them.

- `{"t":"share.text","text":"..."}`: UTF-8, not empty, at most 1 MiB. The Mac decides what
  it is: text that is, or contains exactly one, `http`/`https` URL with a host (same syntax
  rules as "Links") opens in the Mac's default browser; anything else — other schemes
  (`file:`, `javascript:`, `intent:`, custom), several URLs, plain text — goes on the Mac
  clipboard. The Mac never opens a non-web URL.
- A file: `{"t":"share.file","id":N,"name":"IMG_1.jpg","mime":"image/jpeg"}`, then
  `SHARE_DATA` frames (`stream` = `id`, ≤ 1 MiB each), then
  `{"t":"share.end","id":N,"size":..,"sha256":"<64 hex>"}` — or `{"t":"share.abort","id":N}`.
  `id` is a u32 ≠ 0 chosen by the phone. One file at a time: a new `share.file` abandons an
  unfinished one, and so does the end of the session.
- The phone sends a file's JSON messages and its data in order on the lowest send priority
  (after video), so they never overtake each other and never delay other replies.
- The Mac accepts only `mime` `image/*`, at most 50 MiB (52 428 800 bytes); larger, a size or
  SHA-256 mismatch, or `share.abort` → nothing is kept. `name` is untrusted: the Mac keeps
  only `[A-Za-z0-9 ._-]`, never a path, and numbers it on collision.

## Drop Mac → phone

What a Finder drag onto a phone window delivers (docs/design/dragdrop.md). Only the Mac sends
these; the phone never answers `drop.*` other than below.

1. Mac → `{"t":"drop.start","id":N,"name":"report.pdf","mime":"application/pdf","size":S,"sha256":"<64 hex>","index":i,"count":n}`,
   `id` a u32 ≠ 0 chosen by the Mac, optional `"resume":bytes` (see 3) and optional
   `"target":"<package>"` (the app of the window the drop landed on; absent on the Deck, a
   phone-mode window and a link window). `index` (1-based) and `count` place this file in one
   gesture's batch: one ⌘V or one drop of several files sends `count` drops of one file each,
   one at a time, with `index` 1…`count` in order; both default to 1 (a single file). One drop
   per phone: while one is running a new `drop.start` answers
   `{"t":"drop.result","ok":false,"code":"busy"}`. The phone validates (`name`
   `[A-Za-z0-9 ._-]{1,100}`, `size` > 0 and ≤ 200 MiB (209 715 200 bytes), `mime` non-empty
   UTF-8, `sha256` 64 lowercase hex, `target` when present a package name
   `[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+` of at most 255 bytes, `index` and `count`
   integers with 1 ≤ `index` ≤ `count` ≤ 1000) and answers
   `{"t":"drop.result","id":N,"ok":false,"code":"bad_request","message":...}` anything else.
2. Mac → `DROP_DATA` frames with `stream` = `id` (each ≤ 1 MiB). The phone counts bytes against
   the announced `size`; more, or a stalled sender, fails the drop.
3. **Resume**: with `"resume":bytes` and a partial temp file from a same-`(name,size,sha256)`
   drop, the phone replies `{"t":"drop.progress","id":N,"bytes":verified}` (the offset) and
   appends from there; anything else answers `bytes:0` and restarts.
4. Phone → `drop.progress {id, bytes}` at most 4 per second (plus once with the last byte),
   then exactly one `drop.result`: success `{"ok":true,"path":"/sdcard/Download/Contigua/<name>"}`
   (the sanitised name, " 2", " 3"… on collision), failure `code`/`message` from `bad_request`,
   `too_large`, `busy`, `checksum` (the finished bytes' SHA-256 differs; the file is removed),
   `cancelled`, `failed`.
5. Mac → `drop.cancel {id}` any time; the phone abandons, removes partial data and replies
   `drop.result` `cancelled`. A session that ends abandons its drop.

The phone writes every byte to a hidden temp file in `/sdcard/Download/Contigua/`, renames
only after the SHA-256 matches, and media-scans the file. A gesture's files are collected as
they land; after the **last** one (`index` = `count`) the phone offers one SEND for the batch
with the app's FileProvider content URIs (docs/design/dragdrop.md): `ACTION_SEND` for one file,
`ACTION_SEND_MULTIPLE` for 2–5, with `FLAG_GRANT_READ_URI_PERMISSION` and the ClipData grant on
every URI. With more than 5 files it saves all of them and offers no SEND. When `target` is
present and that package resolves the SEND intent for the batch's MIME the SEND is aimed at it
with `setPackage` and shows no chooser; a package that is absent, not installed or has no
matching activity gets today's chooser. A new target, a repeated `index` 1 or a different
`count` starts a new batch, so a lost file can never block the next gesture.

## Phone files

Browsing and writing the phone's shared storage from the Mac (docs/design/
files.md §3). One session, multiplexed like everything else. The phone is
stateless across requests: no index, no cache, no lock table beyond the
running transfers.

- **Paths are relative to shared storage**, `/storage/emulated/0` (`""` = the
  root). A path is rejected with `fs_denied` when it is absolute, contains `\`
  or NUL, is longer than 4096 bytes or 32 `/`-separated components, has an
  empty, `.` or `..` component, canonicalizes outside the root (a symlink must
  not escape it), or names `Android/…` or a dot-prefixed top-level entry.
  Anything missing is `fs_not_found`; a `fs.list` of a file is `fs_not_a_dir`.
- **`fs.list`** answers one page of at most 1000 items and at most 1 MiB of
  JSON. `page` is an opaque string the phone chose; a page that is absent or
  unknown starts at the first item. `fs.items.page` is `null` on the last page,
  which also carries the folder's `digest` (below).
- **Android's transient entries** — `.trashed-*` (a file moving into the Trash)
  and `.pending-*` (a staged delete) — are left out of every listing and every
  digest, at any depth, like our own `.contigua-*.part` staging files. They
  are not items, so they neither fill a page nor move the cursor.
- **Items** are `{"name","dir","size","mtime","ino","etag"}`: `size` and
  `mtime` (ms) are the file's own, `ino` its inode (0 when unknown), `etag`
  16 bytes of `(ino, size, mtime)` as 32 lowercase hex characters — a weak
  version that changes with any metadata change. No per-item path: the parent
  is the request's path. A list never hashes file contents.
- **`fs.read`** streams the requested range as `FS_DATA` frames (`stream` =
  `id`, each ≤ 256 KiB) and ends with `fs.read.end` carrying the range's size
  and SHA-256. Chunks are paced like share-in: at most 1 MiB queued, so at
  most four 256 KiB frames are in flight. `offset` + `length` must lie inside
  the file (the last byte may be EOF, a zero length reads nothing and ends
  immediately) — anything else is `fs_denied`. A stale or absent file is
  `fs_not_found`; a directory is `fs_not_a_dir`. With `etag` present and
  different from the file's current one, the answer is `fs_stale` and no data
  is sent.
- **`fs.cancel`** stops that read (or that thumbnail, below): the phone sends no further `FS_DATA` for the
  id (queued chunks are dropped), and the Mac discards what it already has.
  Frames for a cancelled or unknown `id` are dropped. A session that ends
  abandons every running read.
- **Ids and caps**: `id` is a u32 ≠ 0 chosen by the Mac, one request in flight
  per id; the phone runs at most 8 reads at once and answers `fs_busy` past
  that. Every reply carries its `id`; fs failures are the ordinary `error`
  message with an `id` field.
- **Logs carry no names**: counts, lengths, depths and codes only, both sides.

### Digests

A digest lets the Mac compare a folder it is not showing without listing it
(FILES-33): on every session ready it asks for the folders in its record and
re-lists only the ones whose digest moved.

| t | fields | meaning |
|---|---|---|
| `fs.digest` | `id`, `paths`: up to 64 folder paths | the folders to hash, in one request |
| `fs.digest` | `id`, `digests`: `{path: "<32 hex>" \| "not_found"}` | the phone's one answer |

The digest is the first 16 bytes, as 32 lowercase hex characters, of SHA-256
over the folder's **visible** entries (the `fs.list` filter), sorted by name
bytes (UTF-8), each written `name \0 ino \0 size \0 mtime \n` with `ino`,
`size` and `mtime` (ms) in decimal ASCII. It is deterministic across phone
restarts and costs one readdir plus one stat per entry, with no recursion.

A path that is not a folder answers `"not_found"` (missing, or a file); the
shape rules are checked as for `fs.list`, and a refused path fails the whole
request with `fs_denied` rather than being mistaken for a deletion. More than
64 paths, or a `paths` that is not a list of strings, is `fs_denied`.

A phone that does not know an `fs.*` message answers `error` with code
`fs_unknown` and the request's `id`; the Mac then re-lists every folder in its
record instead (paged as today).

### Thumbnails

Finder's icon grid asks for a picture before the file is downloaded (docs/design/files.md "Thumbnails (S6)"): the phone makes one from the media file itself, with no cache and no prefetch.

| t | fields | meaning |
|---|---|---|
| `fs.thumb` | `id`, `path`, `size`, `etag`? | one thumbnail of the file at `path`; `size` is the long side in pixels the Mac wants (1–4096) and `etag` is checked exactly as `fs.read`'s |

`fs.thumb`'s `size` is pixels, the one place the wire uses that name for
something other than a byte count; `fs.thumb.end`'s `size` is bytes, as
everywhere else. The answer is the image's bytes as `FS_DATA` frames (`stream`
= `id`, each ≤ 256 KiB; the whole answer is at most 256 KiB, so one frame in
practice), then:

| t | fields |
|---|---|
| `fs.thumb.end` | `id`, `mime`, `size`, `sha256` — `mime` is `image/jpeg` or `image/png`, `size` the byte count, `sha256` its digest |

Rules:

- The phone makes the picture at shell uid with the platform's own image/video
  thumbnail generator, long side `min(size, 512)`, JPEG at quality 80, or PNG
  when the bitmap has alpha and the item is an image (a video frame is always
  JPEG). The whole answer is at most 256 KiB (262 144
  bytes): a larger first encode is re-encoded once at quality 60 (a PNG over
  the cap becomes a flattened JPEG), and if that is still larger the answer is
  `fs_no_thumb` with no bytes sent.
- One at a time: the phone accepts at most 3 live `fs.thumb` ids and answers
  `fs_busy` past that; the accepted ids wait in a FIFO and the phone generates
  **one** at a time. The frames and `fs.thumb.end` ride the **bulk lane**
  `fs.read` uses (the session's lowest send priority, below video deltas; at
  most 1 MiB queued, so the producer blocks instead of buffering), so a
  thumbnail never overtakes a reply and never delays a stream.
- Refusals: a path the shape rules reject is `fs_denied`, a missing file
  `fs_not_found`, a directory `fs_not_a_dir`, an `etag` that no longer matches
  `fs_stale` (no bytes sent), a `size` outside 1–4096 `fs_denied`, and a file
  the phone cannot make a picture of `fs_no_thumb`.
- `fs.cancel` stops one: a queued id is dropped before it generates anything, a
  running one is cancelled through the platform's cancellation signal, and the
  Mac drops frames for a cancelled id (as for a read).
- Nothing runs unless a Mac asks: no thumbnail is made at session start or on a
  listing, and a folder never gets one. A thumbnail never wakes the phone's
  screen, takes no wake lock and never starts a stream.
- No version bump: `fs.thumb` and `fs.thumb.end` are new `t` values and
  `fs_no_thumb` a new code; nothing existing changes shape. A peer that does
  not serve the request simply never answers, which the Mac's 8 s deadline
  bounds (a `fs.cancel` follows).

### Writing

`FS_DATA` also travels Mac → phone: `stream` = the request `id`, each frame
≤ 256 KiB, paced like a drop (at most 1 MiB queued, so at most four frames in
flight). The phone writes into a hidden temp in the target folder
(`.contigua-<random>.part`, never listed), verifies size and SHA-256, then
renames over the target — through the MediaProvider path where the platform
has one, `renameTo` plus a media scan of both paths otherwise — and scans the
final path so the file appears in Files/Photos. A cancel or a session end
deletes the temp; a failed write never leaves a partial file under the
target's name. A write never replaces a directory.

| t | fields | meaning |
|---|---|---|
| `fs.write` | `id`, `path`, `size`, `sha256`, `etag`?, `exclusive`? | stream `size` bytes after the request; `etag` is the version the Mac believes it replaces; `exclusive: true` is a create that must not replace anything |
| `fs.move` | `id`, `from`, `to`, `etag`? | rename/move one entry; `fs_exists` when `to` is taken, `fs_stale` on an etag mismatch |
| `fs.delete` | `id`, `path`, `recursive`, `etag`? | a file always; a folder when empty or `recursive`; `etag` is checked right before the delete |
| `fs.mkdir` | `id`, `path` | create one folder (`fs_exists` when taken, `fs_not_found` when the parent is gone) |
| `fs.setAttrs` | `id`, `path`, `mtime`? | set the modification time, best effort |

Phone → Mac:

| t | fields |
|---|---|
| `fs.progress` | `id`, `bytes` — at most 4 per second, then once with the last byte |
| `fs.result` | `id`, `ok`; on success `item` (the new metadata) and `etag`; on failure `code` and `message` |

Rules:

- A `fs.write` body is at most 1 GiB (1 073 741 824 bytes). A larger announced
  `size` answers `fs_too_large` before a byte arrives. More bytes than
  announced are dropped, the temp is deleted and the write answers `fs_denied`
  ("more bytes than announced") — once, so the Mac never waits.
- `size` and `sha256` are mandatory. A size or hash mismatch removes the temp
  and answers `fs_denied` (the wire's existing "could not write" code); the
  target is untouched.
- With `etag` present and different from the target's current version (or the
  target having appeared or vanished since), the answer is `fs_stale` and the
  temp is deleted. The etag is checked again right before the rename.
- `exclusive: true` means create: a target that exists is `fs_exists` at the
  request (no byte is accepted), and it is checked again right before the
  rename (a file that appeared during the stream stays untouched, the temp is
  deleted). Without `exclusive` and without `etag` an existing target is also
  `fs_exists`: a replace must name the version it replaces.
- One write at a time per session (`fs_busy` for a second id). `fs.cancel`
  stops a write and deletes its temp. A session end does the same.
- `fs.move`, `fs.delete` and `fs.mkdir` are refused with `fs_denied` for any
  path the shape rules reject, `fs_not_found` for an absent source, and
  `fs_exists` when the destination is taken. A non-empty folder deleted
  without `recursive` is `fs_denied`.
- `fs.delete` with an `etag` that no longer matches the entry answers
  `fs_stale` and nothing is deleted: the check runs right before the delete,
  so a stat the Mac made earlier cannot hide a change made since. A folder's
  etag is the folder's own (a child added or removed directly in it moves it);
  a recursive delete removes what is in the folder at that moment, deeper
  changes included.
- `fs.setAttrs` answers `fs.result` with the item; a platform that cannot set
  the time answers `ok: true` with the item's real metadata (best effort).

### Watching

Watching is opt-in and request-scoped (docs/design/files.md §2, §5): the phone
watches a folder only while the Mac says it has that folder open, and nothing at
all while the set is empty.

| t | fields | meaning |
|---|---|---|
| `fs.watch` | `id`, `paths` | add these folders to the watched set; idempotent |
| `fs.unwatch` | `id`, `paths` | remove them; a folder that is not watched is ignored |

Phone → Mac:

| t | fields |
|---|---|
| `fs.changes` | `paths`: the watched folders whose contents moved, coalesced (≤ 4 messages per second per session) |

Rules:

- `paths` holds relative folder paths (`""` = the root). One that the shape
  rules refuse — `Android/…`, a dot-prefixed top-level entry, `..` — answers
  `fs_denied` and adds or removes nothing. An entry that is not a directory is
  `fs_not_a_dir`; one that is gone is `fs_not_found`. A refused batch changes no
  watch.
- Both answer `fs.result` with `ok: true` and no item. `fs.watch` on a folder
  that is already watched is a no-op; `fs.unwatch` on one that is not is a
  no-op, so the Mac needs no exact bookkeeping.
- `fs.changes` carries paths only: no names, no metadata, no deleted list. The
  Mac re-lists each path and diffs against the listing it handed out last, which
  covers creates, edits, deletions and renames in one message. Folders are
  coalesced: a burst inside one folder is one occurrence in one message, and
  messages are at most 4 per second. A change in a folder nobody watches is
  never reported.
- A watch is one folder, non-recursively (inotify semantics); the Mac must ask
  for a child folder itself. Our own staging writes (`.contigua-*.part`) never
  produce a change.
- At most 256 folders are watched per session. Past that, or when a watch cannot
  start, the phone falls back to a 5 s media-generation poll while anything is
  wanted, and reports the affected folders in `fs.changes` when it moves.
- A session end removes every watch and stops the poll. The phone keeps no
  watcher, timer or poll while no folder is watched.


## Notifications + media

Phone notifications and media controls (docs/design/notify.md) travel only
while the Mac's per-phone opt-in is on and the phone's notification listener is
granted. The Mac's switch is the only person-facing one.

Mac → phone:

| t | fields | meaning |
|---|---|---|
| `notify.enable` | `on` | the Mac's per-phone opt-in (the only notification switch); the phone answers `notify.state`, and every `on:true` while forwarding also answers with the active set (`notify.snapshot`) |
| `notify.open` | `id`, `target` (`window`/`phone`), `stream` (window only) | a banner click: run that forwarded notification's own action |
| `notify.action` | `id`, `i`, `text`? | press that forwarded notification's advertised action; `text` only for a reply action |
| `notify.dismiss` | `id` | clear that forwarded notification on the phone |
| `media.command` | `action`: `play`/`pause`/`next`/`prev`/`seek`/`volume`, `key`?, `positionMs`?, `level`? | drive the phone's chosen media session |
| `media.choose` | `key` | pick which phone session Now Playing follows |

Phone → Mac:

| t | fields |
|---|---|
| `notify.state` | `on` — forwarding is live; `reason` — `no_access` when the Mac asked but the phone's listener grant is missing |
| `notify.post` | `id`, `pkg`, `app`?, `when`, `title`?, `text`?, `alert`, `group`?, `ongoing`?, `actions`?, `live`? — the shell server re-validates each field and forwards every one of them |
| `notify.image` | `id`, `mime`, `w`, `h`, `data` (base64) — re-validated by the shell server and forwarded unchanged |
| `notify.remove` | `id` |
| `notify.snapshot` | `ids`: the active set — up to 200 opaque ids the phone still holds, sent once after the quiet `notify.post` for each |
| `media.state` | `playing`, `pkg`?, `key`?, `title`?, `artist`?, `album`?, `durationMs`?, `positionMs`, `rate`, `canSeek`?, `volume`?, `volumeMax`? |
| `media.sessions` | `list`: `[{key, pkg, app, playing}]` in the system's order, `chosen` (`key`?) |
| `media.art` | `key`, `mime`?, `w`?, `h`?, `data`? (base64) — no data clears the picture |

`media.state` describes the chosen session: `positionMs` was measured when the
message was sent and the Mac advances it with `rate`. `key` names the session
`media.sessions` listed; `canSeek` says its `PlaybackState` lists
`ACTION_SEEK_TO`; `volume`/`volumeMax` come from its `playbackInfo` (local
playback is the music stream). A phone that does not send the new fields keeps
working: the Mac then enables no seek command and shows no volume slider, and
it sends no `media.command` volume — without the maximum there is no level to
clamp to, and the Mac never guesses one.

`media.sessions {list, chosen}` lists the active sessions in the system's order
as `{key, pkg, app, playing}` — an opaque per-session `key` the phone mints, the
package, the app label, and whether it is playing. Never a title, artist or
album. `chosen` is the key `media.state` describes. The list is sent when it
changes; a Mac that does not know the message ignores it and keeps today's
single-session Now Playing.

`media.art {key, mime, w, h, data}` carries the chosen session's artwork for that
session key: `image/jpeg`, long side ≤ 512 px, at most 256 KiB encoded, `data`
its base64 bytes. It is sent once per change (the phone dedupes by a hash of the
scaled bytes); `media.art {key}` with no data means the session has no artwork
and clears it. The Mac uses it as the Now Playing artwork and does not persist
it. A phone that does not know the message never sends it; an older Mac ignores
it.

`media.command` names an optional `key`: with a key it acts on that session
only, and an unknown key is ignored with a log line. Without one it acts on the
chosen session, which is also what every command from an older Mac does.
`action: seek` carries `positionMs` (clamped to `[0, durationMs]` on the phone
before `transportControls.seekTo`); `action: volume` carries `level`, clamped to
`[0, volumeMax]` before `setVolumeTo(level, 0)`. Both clamps are applied on the
phone, which logs the value it used. `media.choose {key}` sets which session the
phone describes: an unknown key changes nothing and logs it. Older phones ignore
`media.choose` and `media.art` like any unknown `t`; older Macs ignore the new
`media.state` fields and `media.sessions`.

The **active set** answers `notify.enable {on:true}`: at session start and again when the
Mac repeats the opt-in after a same-session rejoin that followed an outage (NOTIFY-1/PATH-6).
The phone re-posts every notification it still holds with `alert:false` (the same shape as
the original post, no picture), then sends one `notify.snapshot {ids}` naming exactly the ids
that went out. The Mac updates a known row/banner in place, presents nothing, and drops every
row, banner and waiting post the set does not name — so a notification the phone ended
during the outage leaves the Mac. `ids` is bounded (at most 200, each ≤ 64 characters of
`A-Za-z0-9-._`, deduped); a malformed entry is dropped and the rest still go out. The ids are
opaque tokens the phone issued in `notify.post`, never content. A repeated enable with the
same value is not ignored: while forwarding it asks for the set again.

`alert` is required on every `notify.post` and is Android's own decision: `true` for the
first post of an id and for an update the app did not silence, `false` for an update that
carries `FLAG_ONLY_ALERT_ONCE` or whose title and text did not change since the last
forwarded post (the phone compares hashes kept in memory, never the text). The Mac presents
an alerting post as a banner and replaces a delivered banner for a non-alerting one with
`interruptionLevel = .passive`, so nothing is presented again. A post without `alert` is
malformed and is ignored; there is no older-peer mode (AGENTS.md).

`group` is present only when the Android notification belongs to a group, and is 16 lowercase
hex characters: 64 bits of SHA-256 over the package and the Android group key, never the key
itself (apps put chat or folder names in it). The phone leaves a `FLAG_GROUP_SUMMARY`
notification on the phone while a forwarded child of its group is active, sends
`notify.remove` for a forwarded summary when a child of that group supersedes it, and forwards
a summary only while its group has no forwarded child. The Mac threads the banner under
`<phone id>.<group>` when `group` is present and under the phone id otherwise; a value that
is not that 16-hex shape is ignored and the banner joins the phone's thread.

`actions` is an array of up to 3 `{"i": <index in the phone's Notification.actions>, "title": "≤ 64 chars", "reply": true?}`; `reply` marks an action with a free-form RemoteInput.
A Mac that does not know the field ignores it. `notify.action` names only an id the phone
issued and an advertised index (0–2); its `text` is at most 4 KiB and is refused on a
non-reply action or over the cap. The phone answers nothing: the app's own update/removal
comes back as `notify.post`/`notify.remove`. An id or index it does not hold logs
`notify.action unknown` without the text. `notify.dismiss` cancels the phone's notification
(the listener calls `cancelNotification`), skipping ongoing and no-clear ones.

`live` marks an Android 16 Live Update (a **promoted** ongoing notification:
`Notification.FLAG_PROMOTED_ONGOING` set by the system) and carries
`{"progress": 0..1, "chip": "≤ 16 chars", "chrono": <epoch ms>, "countDown": bool}`
— every field optional. `progress` is the notification's ProgressStyle fraction
(segments are summed into one length), `chip` the system's short critical text,
`chrono` the `when` of a chronometer notification. An update is a second
`notify.post` with the same `id`; the phone coalesces updates to at most one per
second per id. The first post of such an id banners on the Mac, later ones update
in place and never banner again; `notify.remove` ends the item. A phone that does
not know `live` never sends it; an older Mac ignores it.

`notify.image {id, mime, w, h, data}` follows the `notify.post` for the same id:
one picture from that notification, `mime` `image/jpeg` or `image/png`, `data` its
base64 bytes (≤ 200 KiB encoded, long side ≤ 512 px). The Mac decodes at most
256 KiB, refuses other mimes and w/h over 1024, and attaches the picture to the
banner it posts within 300 ms of the post; a late image is dropped rather than
re-bannering. A Mac that predates the message ignores it.

`notify.open` carries only an id the phone issued in `notify.post`: the Mac
never sends an intent, a package or a component. `target: window` names the
stream the Mac opened for the app; the phone runs the notification's
`contentIntent` on that window's virtual display (after the launcher activity,
so the chat opens in the Mac window). `target: phone` runs it on the phone's
own display 0 and opens no Mac window. An id the phone no longer holds is a
no-op (`notify.open unknown id`); a send that cannot run (the action is
cancelled or is not an activity) logs `notify.open fallback reason=<class>` and
leaves the app's window at its launcher activity. A phone that does not know
`notify.open` ignores it like any unknown `t`; with `target: window` the app's
window is already open at its launcher activity, which is the previous
behaviour. Notification text is never logged on either side.

## Clipboard images

Both directions while a session is ready; same announce → chunks → end as `share.file`, but
the sender may be either side:

- `{"t":"clip.image.start","id":N,"mime":"image/jpeg"|"image/png","size":S}`, then
  `CLIP_DATA` frames (`stream` = `id`, ≤ 1 MiB each), then
  `{"t":"clip.image.end","id":N,"size","sha256":"<64 hex>"}` — or `{"t":"clip.image.abort","id":N}`.
  Ids are per direction, from 1. The Mac may add `"paste":true`: the image is a person's own ⌘V in
  a window, so it applies even while `clip.enable` is off (SHARE-16); nothing else changes.
- The phone answers a Mac image with `{"t":"clip.image.done","id":N,"ok":true}` after the bytes
  verify **and** its clipboard holds the image; `{"ok":false}` when it refuses (a checksum
  mismatch, no clipboard to write to, or over the cap). The Mac sends nothing else on that id,
  and a paste flow waits for `ok:true` (docs/specs/share-clipboard.md SHARE-16). The bytes are
  copied by the **app process**, which owns the provider and the clipboard: the shell hands it
  the already-open fd (`onClipImage`) and waits at most 3 s for `clipImageDone`; no answer is
  `ok:false`. The app writes one clipboard item carrying only the image URI (no text, no
  intent): a plain field pastes nothing (a content URI that cannot serve text coerces to null,
  never to its `content://` string), while a field that accepts image content still gets the URI
  (SHARE-2's A2 rule, measured on the emulator). The shell never sets an image clip itself.
- At most 8 MiB (8 388 608 bytes) per image. Larger: the sender stays silent, a receiver that
  sees `size` over the cap ignores the image — the `clip.set` rule for bytes.
- One image in flight per direction: a new `clip.image.start` replaces the unfinished one, and
  session end discards it.
- The Mac sends an image when the general pasteboard changes to an item with image data and no
  text (PNG verbatim, TIFF converted to PNG) and it is not marked concealed by a password
  manager. It also sends a Finder copy of exactly one image file this way: PNG and JPEG
  verbatim, any other image type re-encoded (PNG with alpha, JPEG at quality 0.9 when
  opaque), the result at or under the cap; the file's name is
  never sent as text (SHARE-2). From the phone the image is read out of the clipboard's first
  item when its bytes are readable. The receiver keeps the SHA-256 of the bytes it last sent
  or received, so images are never echoed back, like `clip.set`.
- A paste into the phone's focused field follows a confirmed image: after `clip.image.done`
  with `ok:true` the Mac sends one `KEY` frame with keycode 279 (`KEYCODE_PASTE`) and
  `metaState` 0 for that stream (docs/specs/share-clipboard.md SHARE-16).

## Ring

`phone.ring` finds the phone (docs/design/intents.md): the **app** — not the shell service,
which has neither UI nor audio — plays the default alarm sound at the alarm volume, over the
lock screen, for at most 30 s.

1. Mac → `{"t":"phone.ring","seconds":N}` — `seconds` optional, clamped 1..30 (default 30).
2. The phone shows an activity over the lock screen (`showWhenLocked`, screen on) with a
   Stop button, holds transient audio focus on the alarm stream and loops the default alarm
   tone. It stops by itself after N seconds, when Stop is tapped, or on audio-focus loss.
3. Phone → `{"t":"ring.state","ringing":true}` once the ring started.
4. Mac → `{"t":"phone.ring.stop"}`: the phone stops at once and answers
   `{"t":"ring.state","ringing":false}`. The session ending stops it too.

A phone build whose app process cannot show the ring answers `error` `unsupported`; the
shell service never rings on its own.

## Ringer

The Control Center ringer control (docs/design/controls.md) sets one of the phone's three
ringer modes. It never touches a volume level, the lock settings or any other setting.

1. Mac → `{"t":"phone.ringer","mode":"normal"|"vibrate"|"silent"}`. The phone writes it at
   shell UID with `cmd audio set-ringer-mode NORMAL|VIBRATE|SILENT` and sends `state` again
   with `ringer` set to the mode it now reports (`Settings.Global.mode_ringer`: 0 silent,
   1 vibrate, 2 normal).
2. A mode other than the three above answers `error` `bad_request`; nothing changes.
3. The phone refuses the write while its Do Not Disturb is on (`error` `dnd_on`): on
   Android 16 a ringer change can end an "alarms" DND, and Contigua does not turn off a
   DND on the side. The Mac checks `state.dnd` first and does not send.
4. A phone that predates the field omits `ringer` from `state`, and `phone.ringer` is an
   unknown message to it. An older Mac ignores the new field.

## Volume

The phone panel's volume slider (docs/design/controls.md) reads and sets the phone's music
stream volume, `STREAM_MUSIC`. It never touches the ringer mode, Do Not Disturb or any
app's own playback volume (`media.state`'s `volume`/`volumeMax` stay per session).

1. Every `state` carries `volume` (the level) and `volumeMax` (the stream's maximum)
   together. Both are read at shell UID through `AudioManager`, with
   `cmd media_session volume --stream 3 --get` as the fallback. They are absent — both,
   never one — on a phone that cannot read the stream; the Mac then disables its slider
   and names that reason instead of guessing a level.
2. Mac → `{"t":"phone.volume","level":N}`. The phone clamps `N` into `0…volumeMax`, writes
   `STREAM_MUSIC` with flag 0 (no volume UI, no vibration), and skips a write that would
   not change the level. It answers with a fresh `state` carrying the level and maximum it
   reads back, never the requested number.
3. A missing `level` answers `error` `bad_request`; a phone with no volume control answers
   `unsupported`; a write the phone refuses, or cannot read back, answers `unavailable`.
4. A change the person makes on the phone arrives as the next `state`: while a session is
   up the shell service re-reads the stream at most once a second, and that read is the
   source (this platform's public API has no volume callback).
5. A phone that predates these fields omits them from `state`, and `phone.volume` is an
   unknown message to it. An older Mac ignores the new fields.

## Phone screen

The phone window mirrors display 0 (docs/design/phone-mirror.md), so its picture is only
live while the panel is on.

1. Every `state` carries `screen`: `"on"` or `"off"`, display 0's power state at shell UID
   (`PowerManager.isInteractive`; doze and doze-suspend read as off). It is sent on change,
   from a display listener on display 0 — no polling. A phone that predates the field
   omits it, and the Mac reads that as "on".
2. `{"t":"phone.wake"}` wakes display 0 without unlocking it: the display-scoped
   `wakeUpWithDisplayId(0)` at shell UID, else `input keyevent KEYCODE_WAKEUP`. The phone
   logs `phone.wake ok`, `phone.wake fallback` or `phone.wake failed` and sends a fresh
   `state`; the next `state` carries the `screen` the phone reports. The keyguard stays,
   no lock or screen-timeout setting changes, and the panel sleeps again on the phone's
   own timeout.
3. The Mac sends it when a phone window opens, is reopened or reconnects, and from the
   window's Wake Screen button. Nothing else sends it.
4. "Turn Off Phone Screen" (`{"t":"phone.panel","off":true}`) holds the panel's power mode
   off while the phone window keeps rendering. The phone reports `state.panel` `"off"` only
   while it actually holds the panel. The hold ends — and the panel is always handed back
   (power mode NORMAL) — on `off: false`, on the person's power press, when the phone window
   closes, when the session ends or disconnects, and on the crash watchdog. A phone window
   that only pauses (covered, minimised) does not end the hold: the phone suspends it (panel
   back, `state.panel` `"on"`), keeps the request, and applies it again when the window
   resumes. One power press brings the screen back by default.
5. `ignorePower: true` (the Mac's "Keep the phone screen off until I turn it on from the Mac"
   setting, off by default) changes only what a power press does: the press lights the screen
   until the next keep-alive step re-applies the panel off, and the hold stands. It never
   outlives the ends in point 4, so the phone cannot stay dark without a Mac holding it. The
   phone stays locked either way.
6. A power press with app windows open changes nothing for them: every app window runs on a
   virtual display in a display group of its own (docs/specs/app-windows.md WIN-74), so the
   phone locks, sleeps and wakes as it would with no window open, and the windows keep
   rendering and taking input. The phone sends nothing on that edge. (Until #142 a build that
   put the window display in the panel's group got a dark-panel take-over and one
   `{"t":"power.locked"}`; the phone no longer sends it, and a phone that cannot give a
   window its own group refuses the open with `windows_unsupported`.)

## Foreground app

The panel's "Open <App> on Mac" row names the app in front without opening a stream
(docs/design/handoff.md). It is a **pull**, never a watch:

1. Mac → `{"t":"task.front","seq":N}`. The phone reads `IActivityTaskManager.getTasks`
   once at shell UID and picks the same task `task.continue` would (`ForegroundTaskPicker`):
   display 0, not our app, not home, not SystemUI, with a package. It answers
   `{"t":"task.front","seq":N,"pkg":"…"}`, or `pkg: null` when nothing continuable is in
   front. No display opens, no HOME key is pressed and no task moves.
2. The package is the only payload: no label, title or activity. The Mac resolves the app's
   name and icon from the `apps` list it already has and logs only `front: present|none`,
   never the package.
3. The Mac asks once when the card opens and at most once every 2 s while it stays open, and
   once per MCP `phone_status` call (docs/specs/mcp.md MCP-32) within the same 2 s budget:
   a request less than 2 s after the last one, from either, reuses that answer. It asks at
   no other time (a Mac-side rule; the phone is unchanged). A reply whose `seq` is not the newest request is
   stale and ignored. `not_available` (no task-manager access) and `pkg: null` both leave
   the row off; nothing else changes on the phone.

## UI tree

The MCP `ui_tree` tool reads a window's screen as accessibility nodes instead of pixels
(docs/design/mcp.md, WIN-79). It is a pull, one read per call. The phone answers any
paired session: the Settings › Automation switch is the Mac's own gate on the tool, not
something the phone checks.

Items 1–5 are the read as #162 shipped it:
the phone sends no `ref` and the Mac names refs `s<snapshot>e<row>` from its own per-window
read count (S1); the reply carries `size: [w, h]`, the pixel space of `box`, and `at` is
TOUCH's 0..1 input space (S2); `windows`/`w` become `layers`/`l` (S3); a node off the display,
not visible to the user or under 8×8 visible pixels carries `off: true` and no `at`, and `box`
is clipped to the display (F9). Items 6–10 are epic #171's wire changes on top of that, each
named with the task that adds it (docs/design/mcp-plan.md). The protocol version stays 4: an
older phone ignores an unknown `t` or request field, and the Mac's deadline answers for it.

1. Mac → `{"t":"ui.tree","stream":N,"seq":S}`. The phone finds the display the stream's
   window lives on and reads that display's accessibility tree at shell UID through
   `UiAutomation`. Only the shell can: an accessibility service sees only the display it
   runs on, and `uiautomator dump` only reads display 0, so neither can see an app window
   on its own virtual display (ISS-143). The phone holds one `UiAutomation` connection
   per process, shared by every session and dropped only when the service stops, never
   when a session ends.
2. The phone trims the tree before sending it. The reply is
   `{"t":"ui.tree","stream":N,"seq":S,"ok":true,"displayId":D,"size":[w,h],"truncated":B,"layers":[…],"nodes":[…]}`:
   - `size` is the display's pixel space — the space `box` is in and TOUCH maps over
     (display 0's real size for a mirror, the virtual display's size otherwise), not the
     stream's video size.
   - `layers`: one row per window on the display — `i`, `title`, `type` (`app`, `ime`,
     `system`, `overlay`, `divider`, `magnifier`, or the platform's number), and `active`
     on the one layer with input focus (item 9, B6; no `focused`).
   - `nodes`: one row per node worth reading, in document order (the reading order):
     `i` the index, `p` the nearest kept ancestor's index (absent at a root), `l` the
     layer's index, `role` the class's last part (`Button`), `text`, `desc` (absent when
     it repeats `text`, except on an editable row, which keeps its `desc` always: a field's
     text is only what it holds now, MCP-86), `id` the view id's part after `:id/`, `box`
     `[left,top,right,bottom]` in display pixels (clipped to the display), `at` the box's
     centre as 0..1 of the display's input space (the same coordinates TOUCH and the MCP
     `tap` tool take), and the states that are true: `click`, `edit`, `scroll`, `check`
     (true **or** false, only when the node is checkable), `sel`, `focus` (only in the
     active layer, item 9), `disabled`, `pwd`.
   - A node whose box does not intersect the display, that is not visible to the user, or
     whose visible part is under 8×8 px is `off`. Since B6 it is left out of the reply and
     counted (item 9); a read that asks `offscreen: true` keeps it with `off: true` and no
     `at`, its text still there so a reader knows to scroll. A tap by its ref is refused
     either way. `box` is the clipped part and `at` the centre of it, never a clamped
     outside point. The platform clips a view's screen bounds to its parent, so a row
     scrolled out of its list arrives with an empty screen box: when its bounds in its
     parent are not empty it is `off` like any other (counted, and sent with no `box` on an
     `offscreen` read), not a node with no drawable bounds.
   - A node with no text, label, action or state, or with no drawable bounds (no size of
     its own: its screen box and its bounds in its parent are both empty), is folded
     away and its children take its place; only what a reader or a model can act on is
     sent. A password node carries no `text` or `desc` at all, only `pwd`. Code points in
     Unicode's private use areas (U+E000–U+F8FF and the two supplementary areas) are
     dropped from a label: an icon font draws art there, not a word, and a label made only
     of them is no label.
   - The phone sends no `ref` and no `snapshot`. The Mac keeps a read counter per
     window (starting at 1, kept across reconnects), and `snapshot` in the tool result is
     that counter. S1 named each node `s<snapshot>e<row>` and refused a ref from any reply
     but the window's latest; since T10 the Mac names a row `e<k>` from its key (item 9), a
     ref from any earlier read is sent back as `ui.press` with that `k` (item 8), and the
     phone, not the Mac, decides whether the node is still there, visible, uncovered and
     labelled as the asking client last saw it. A row with no `k` has no ref.
   - At most 1200 nodes and 200 characters per label. `truncated` says the cap cut the
     tree. `displayId` is the display's own id (a virtual display's is in the sixties on
     current builds), never a counter.
   - An empty tree keeps `nodes: []` and carries a `note` saying the display has no
     accessible content, so an empty list is never read as a blank screen.
3. A read that cannot happen answers
   `{"t":"ui.tree","stream":N,"seq":S,"ok":false,"code":C,"message":"…"}` with `no_window`
   (no such stream), `not_available` (this phone cannot read a tree), `busy` (the previous
   read is still running), `no_display` (the display went away), `no_a11y` (the platform
   refused the connection) or `failed`. A `ui.tree` without a `stream` answers `no_window`,
   never a silence.
4. One read at a time per session. The Mac serializes `ui_tree` calls per session, so a
   second window's read waits for the first instead of being refused `busy`; it asks only
   when the tool is called and waits at most 5 s. The phone's own connect step has a
   shorter deadline, so a phone that cannot connect answers before the Mac's deadline. A
   late reply whose read already timed out is ignored: it neither resolves a read nor
   replaces the window's refs.
5. Text is on-screen content: it travels in this message and into the tool result, never
   into a log line. The phone logs the stream, display, layer and node counts and the
   duration; the Mac logs the tool name, its duration, its outcome code and the window id.
6. **One `ui.*` request at a time (B1).** `ui.tree`, `ui.settle`, `ui.press` and `ui.type`
   share item 4's rule: one per session. The phone answers a second one while the first runs
   with `ok: false`, `busy`; the Mac queues its own requests so it never sends one
   (docs/specs/mcp.md MCP-9). The Mac waits at most its read deadline past the request's own
   time (for `ui.settle`, its `timeoutMs`; for `ui.type`, 10 ms per code point of its text,
   item 10).
7. **`ui.settle` (B1).** Mac → `{"t":"ui.settle","stream":N,"seq":S,"quietMs":Q,"timeoutMs":T}`,
   `Q` 100–2000 and `T` 200–10000 (the MCP tools send 300 and 2000); a value outside its
   range is clamped, and then `Q` is clamped to at most `T`. The phone listens to `UiAutomation`'s accessibility events and counts
   the content changes — `TYPE_WINDOW_CONTENT_CHANGED`, `TYPE_WINDOW_STATE_CHANGED`,
   `TYPE_WINDOWS_CHANGED`, `TYPE_VIEW_TEXT_CHANGED`, `TYPE_VIEW_SCROLLED` — whose window is on
   the stream's display (by window id, from the latest `windowsOnAllDisplays` read, refreshed
   when the watch starts, on every `TYPE_WINDOWS_CHANGED`, and once for each window id it does
   not know; an event whose window that refresh no longer lists counts when the read before it
   placed the window on the display, so a window removed from the display is a change); every
   other event type is ignored. The connection asks for no event type at all
   while no watch runs, and for only these five while one does. A display listed with no window, or not listed yet, is still opening: it counts as loading at the start and at every check, and its first window is a counted change. When no counted event came for
   `Q` ms it checks the display for a loading signal (item 9's `loading`) and answers only
   when there is none, else watches on and checks again after every later quiet period; at
   `T` ms it answers whatever the state. The reply is
   `{"t":"ui.settle","stream":N,"seq":S,"ok":true,"settled":B,"waitedMs":W,"events":E,"reason":R}`
   — `settled` true for a quiet display with nothing loading, false at the timeout; `reason`
   only when `settled` is false: `"loading"` (the last check found a loading signal and no
   change came after it) or `"changes"`; `waitedMs` from the request's arrival; `events` the
   counted events. The whole request answers by its arrival + `T` + 2.5 s, under the Mac's
   `T` + 5 s. A session that ends during its watch, or before its watch starts — the phone still
   connecting, or no `ui.tree` or `ui.settle` has started the watch thread yet — stops it, and
   nothing is sent. The watch starts when the phone reads the request: input frames sent
   before it on the session's ordered reliable lane have been injected by then. A watch that
   cannot happen answers
   `{"t":"ui.settle","stream":N,"seq":S,"ok":false,"code":C,"message":"…"}` with `no_window`,
   `no_display` (the display had a window and went away during the watch; a stream with no display at the start answers `no_window`), `not_available` (this phone cannot
   listen to accessibility events, or its connection could not be made: never `ui.tree`'s
   `no_a11y`), `busy` (item 6) or `failed`. The watch is a pure state
   machine (docs/specs/mcp.md "Settling a display"); it reads event types, window ids and the
   loading check's yes or no, and logs the stream, the outcome, `waitedMs` and `events`.
8. **`ui.press` (B3).** Mac → `{"t":"ui.press","stream":N,"seq":S,"k":K,"holdMs":H,"expect":"…"}`,
   `k` a row's key (item 9, B2), `holdMs` optional (absent = a tap; 1–3000). `expect` is the
   node's label as the Mac last answered it to the connection that asks: the row's `text`, else
   its `desc`, else the first on-screen row under it with either, in reading order (a row
   marked `off` gives none of its own), where a row with
   `edit` gives none and neither do the rows under it; an `edit` row's own label is its `desc`,
   else its `id`, never its `text` (a field's text is its value, not what it is; item 2 keeps a
   field's `desc` even when it equals its `text`, so the label never depends on what was typed),
   and a `pwd` field, whose row carries no `desc`, is labelled by its `id` alone; absent when the Mac
   has no label for `k` (it never answered that connection a tree with `k`, or no row there
   carried one — a capped tree may have cut the labelled rows), so the phone does not check. The phone finds `k` in
   its latest read of the stream's display, calls `refresh()` on that node and, when it still
   exists, is `isVisibleToUser` and is on the display (item 2's `off` rule), reads its bounds
   now, computes the covering node as `covered` does (item 9) at the bounds' centre, reads the
   same label of the refreshed node (its text, else its description, else the first node under
   it with either that the tree would keep and not mark `off` — item 2's rule, the same
   predicates as the row's `off` and fold: a node with no drawable bounds gives no label and
   its own children take its place — depth first within item 2's depth cap, each trimmed as
   item 2 trims a label;
   an editable node is labelled by its description, else its view id as item 2 shortens it, a
   password one by its view id alone, and
   under another node an editable node and its subtree give none),
   and — when nothing covers it and the label equals `expect` (or `expect` is absent) — injects
   TOUCH down at the centre and up after `H` ms (or at once),
   stamped like a TOUCH frame from the Mac. It answers
   `{"t":"ui.press","stream":N,"seq":S,"ok":true,"box":[l,t,r,b],"at":[x,y],"role":"Button","text":"…","desc":"…"}`
   with the bounds and point it pressed (display pixels, item 2's input space, three
   decimals) and the node's role, text and description as `refresh()` read them (absent when
   empty; no text for a password field), after the up is injected. A press that does not
   happen injects nothing and answers
   `{"t":"ui.press","stream":N,"seq":S,"ok":false,"code":C,"message":"…"}` with `gone` (the
   key is not in the latest read, or `refresh()` failed), `not_visible`, `off_screen`,
   `covered` (with `"coveredBy"`: a key or `"window"`), `changed` (with `"now"`: the label read
   now — a list reused the row's node for another item, or the node relabelled itself; #188),
   `no_window`, `busy` or `failed`. A key the phone never issued is `gone`. The checks run in
   that order — `gone`, `not_visible`, `off_screen`, `changed`, `covered` — and the first that
   fails answers. A phone that cannot press by element answers `failed`. The phone logs the stream, the outcome,
   whether `expect` came (`expect=yes|no`) and the duration, never the node's text or `expect`.
9. **Row and reply fields of #171**, added to item 2's reply:
   - **`loading` (B1).** A row is kept and marked `loading: true` when it is visible to the
     user and is a `android.widget.ProgressBar` (or a class whose name ends in `ProgressBar`)
     with no `RangeInfo`, or a `android.webkit.WebView` with no child node; the reply carries
     `loading: true` while any row has it.
   - **`k` (B2).** Each row carries `k`, an integer key. The phone keeps, per display, a table
     from a node's identity — its window id and source node id, the pair
     `AccessibilityNodeInfo.equals` compares — to its key. A node seen again in a later read
     keeps its key; a new node gets the next unused one (1, 2, …); a key is never given to
     another node while the display exists. A read drops the table of a display it no longer
     finds listed (`windowsOnAllDisplays` leaves out a display between two windows), but keeps
     that display's next key, so its nodes come back with new keys, never old ones. A node met
     twice in one read gets a second key. At most
     4096 identities are remembered per display; past it the oldest that are not in the latest
     read are forgotten (a forgotten node that returns gets a new key). `k` is unique within a
     reply. The Mac names the row's ref `e<k>` (T10); the key crosses back to the phone only in
     `ui.press` (item 8).
   - **`heading` (B2).** `true` when `AccessibilityNodeInfo.isHeading`.
   - **`covered` (B2).** The `k` of the topmost row whose visible `box` contains this row's
     `at` point and that is drawn after it — a later `getDrawingOrder` where their branches
     part (an ancestor or a descendant never covers), or any row of a layer above this row's
     layer on the display (by `AccessibilityWindowInfo.getLayer`) — counting only rows that
     carry `at` and are clickable or carry a label. A layer above that reaches the point (by
     its window bounds, or a counted row of it there) wins over the row's own layer: the
     highest such layer names its topmost counted row at the point, or `"window"` when it has
     none there. Absent when nothing covers the point, and on a row with no `at`.
   - **`hint`, `hintText` (B6).** A row whose node `isShowingHintText` carries `hint: true` and
     the hint's words as `hintText` (its text when the node reports no hint), and no `text`;
     a field holding content carries `text` and neither hint key.
   - **`active` on a layer; `focus` (B6).** Exactly the layer with input focus
     (`AccessibilityWindowInfo.isFocused`) carries `active: true`, and none when no layer has
     it; a layer carries no `focused`. `focus` is sent only on the row of the node with input
     focus in that active layer (`findFocus(FOCUS_INPUT)` on its root; when that node is not
     editable and hosts a virtual tree with an editable node that reports focus, as a WebView
     does for its focused `<input>`, that node).
   - **Off-screen rows left out; `hidden`, `omitted`, `offscreen` (B6).** A row item 2 marks
     `off` is left out of the reply. A kept row with `scroll` carries `hidden: [before, after]`
     when either is non-zero: its left-out descendants before its first on-screen descendant
     in reading order, and the rest. The reply carries `omitted`, the count of left-out rows.
     A request `{"t":"ui.tree","stream":N,"seq":S,"offscreen":true}` keeps them, marked `off`
     as item 2 sends them; the Mac asks so only for the MCP `find` argument.
10. **`ui.type` (B5).** Mac → `{"t":"ui.type","stream":N,"seq":S,"text":"…","clear":B,"submit":B}`,
    `text` 1–2000 characters, `clear` and `submit` optional (false). The phone finds the node
    with input focus in the active layer (item 9) of the stream's display. Text made only of
    characters `KeyCharacterMap.VIRTUAL_KEYBOARD` can produce is injected as KEY events at the
    cursor, with the key map's meta state and stamped like KEY frames from the Mac (`via: "keys"`); with `clear`, ctrl+A and DEL
    come first unless the focused node takes `ACTION_SET_TEXT`, in which case the text is set
    whole — and with no node holding input focus `clear` answers `no_field` and sends nothing,
    since those keys would reach whatever else has key focus (#270). Any other text is set whole on the focused node: `ACTION_SET_TEXT` with the
    node's text before its selection + `text` + the text after it (a shown hint counts as
    empty; no selection puts it at the end; with `clear`, `text` alone), then
    `ACTION_SET_SELECTION` to just after the typed text (`via: "set_text"`). With `submit`,
    ENTER down/up follows. The phone never reads or writes the clipboard on this path. It
    answers `{"t":"ui.type","stream":N,"seq":S,"ok":true,"entry":E,"via":V,"characters":C}`
    after the last key or action — `entry` `"inserted"`, `"replaced"` (`clear`) or `"unknown"`
    (keys sent with no node holding input focus) — or, typing nothing,
    `{"t":"ui.type","stream":N,"seq":S,"ok":false,"code":C,"message":"…"}` with `no_field`
    (set text needed, or `clear`, and no node has input focus), `not_supported` (the node offers no
    `ACTION_SET_TEXT`, or is a password field holding text without `clear`), `no_window`,
    `busy` or `failed` (the app refused the action, the phone could not read the focused field,
    or `text` is missing or outside 1–2000 characters). Characters are counted as code points. The
    phone logs the stream, the outcome,
    `via`, the character count and the duration, never the text. The Mac waits for the answer
    its read deadline (5 s) plus 10 ms per code point of `text`, from the send (25 s at 2000
    code points), because text sent as keys can take longer than the read deadline; the
    display's window closing or the link dropping ends the wait sooner, and an answer after it
    is ignored.

## Secure screens

Android blanks secure surfaces in a screen capture: a `FLAG_SECURE` app (banking, password
managers) and the lock screen's PIN/password pad. In the display-0 mirror those areas arrive
black, so the Mac must say why instead of showing a dead picture.
1. Once the phone has read it, every `state` carries `secure`: `true` while display 0 shows
   a secure window or the keyguard bouncer, otherwise `false`. It is sent on change. The
   phone reads the focused window's `FLAG_SECURE` at shell UID and SystemUI's bouncer state
   (a debuggable build skips the window flag for the bouncer, a release build sets it).
2. The phone polls this at most once a second, and only while a phone window stream is open.
   With no phone window it stops polling; `secure` is absent until the first read, and the
   last value is cleared when the last phone window closes.
3. A Mac that gets no `secure` field treats the mirror as not secure.

## Focus and Do Not Disturb

A Mac Focus, the menu bar's "Phone Do Not Disturb" and a Shortcut all use the phone's zen
mode (docs/design/focus.md):

1. Mac → `{"t":"phone.dnd","mode":"priority"|"alarms"|"none"|"off"}`. The phone changes
   `Settings.Global.zen_mode` with `cmd notification set_dnd` at shell UID and sends `state`
   again with `dnd` set to the mode it now reports.
2. A mode other than the four above answers `error` `bad_request`; nothing changes.
3. The phone remembers whether Contigua turned DND on. `phone.dnd off` turns it off only
   when that is still the mode Contigua set; a mode the person chose is never turned off.
   The memory lives in the shell service, survives a disconnect and is cleared on reboot.
4. Every `state` carries `dnd` while the phone supports it; a person's change on the phone
   arrives as the next `state`. A phone that predates this field omits it, and the Mac reads
   that as "not supported".

## Error codes

`{"t":"error","code":...}` codes: `busy` (another session is active), `no_session`
(a `hello`'s `join` names a session this phone does not serve: the Mac starts a new
session), `too_many_paths` (a join past the session's 3 paths), `bad_pin` (the
peer's certificate fingerprint is not the pinned one — the Mac shows "This phone's
identity changed. Pair again."), `not_paired` (the phone pins nothing for this Mac
and the Mac did not ask to pair — the Mac shows "<phone name> no longer trusts this
Mac." with Pair again and stops retrying), `pair_denied`, `pair_cooldown`, `pair_commit` (the revealed nonce does
not match the commit), `version` (this side's protocol version differs; `v` carries the
version that refused, so the other side can say which app to update), `protocol` (message not allowed in the current state;
then close), `pair_timeout` (nobody answered the pairing prompt in 120 s; then close),
`pair_exporter` (the phone's TLS stack exposed no exporter, so it cannot derive
the pairing code: the phone refuses to pair instead of substituting a zero key
— shipped Android 11 cannot expose one, so the Mac says to update Android or
Contigua),
`no_stream` (unknown `stream`: never opened, or already closed by its `window.close`;
the Mac sends nothing for a stream it closed and shows no notice for a late answer — a
window still opening is refused on its cover, a live one closes as on `window.closed`),
`forgotten` (the person forgot this Mac, or every Mac, in the phone app while
this session was live: the Mac enters the trust-lost state, makes no further
attempt and shows "<phone name> no longer trusts this Mac." with Pair again; the
phone sends it on the authenticated session and then ends it within the PAIR-20
bound), `launch_failed`, `windows_unsupported` (a `window.open`, `link.open`, `task.continue` or
`window.adopt` on a phone whose window display would share the panel's display group, carrying
the `stream`: the phone released the display and launched nothing, and the Mac's cover says
"This phone can't give app windows a screen of their own.", docs/specs/app-windows.md WIN-74),
`bad_url` (a `link.open` URL that is
not allowed), `bad_size` (`task.continue` without w/h) — plus the device commands'
own codes: `dnd_on` (a `phone.ringer` while Do Not Disturb is on) and `unavailable`
(the phone would not write the ringer setting or the music volume), `connections_off` (the phone's
"Allow connections" switch is off: the Mac shows "Connections are turned off on
<phone name>." with the line "Turn on Allow connections in Contigua on your
phone." and slows to one attempt per 30 s), `pairing_off` (the phone's "Allow new pairings" switch is off and
this Mac is not paired: "<phone name> isn't accepting new pairings."),
`not_available` (the phone can't
report its foreground app, e.g. no task manager access, for `task.continue` or `task.front`), `nothing_to_continue` (the
foreground is our app, the launcher/home or SystemUI), `fs_not_found`,
`fs_denied` (a path outside the readable rules, or a range outside the file),
`fs_not_a_dir`, `fs_stale` (the `fs.read`/`fs.thumb` etag no longer matches the file),
`fs_no_thumb` (the phone cannot make a thumbnail of that file: not an image or
video, an unreadable or unsupported codec, or the answer did not fit 256 KiB)
and `fs_busy` (more than 8 reads, or more than 3 thumbnail ids, in flight), `too_many_windows` (a `window.open` past
the phone's `maxWindows`; no display is created).
The `ui.*` exchanges answer in their own reply with `ok: false` and a `code`, never with an
`error` message: `ui.tree` `no_window`, `not_available`, `busy`, `no_display`, `no_a11y`,
`failed`; `ui.settle` (**wire change, #171 B1**) `no_window`, `no_display`, `not_available`,
`busy`, `failed`; `ui.press` (**wire change, #171 B3**) `gone`, `not_visible`, `off_screen`,
`covered`, `changed`, `no_window`, `busy`, `failed`; `ui.type` (**wire change, #171 B5**) `no_field`,
`not_supported`, `no_window`, `busy`, `failed` ("UI tree" §3, §7, §8, §10).
Oversized frames close the session without a reply. JSON nesting is capped at
64 arrays/objects; deeper input is rejected like any malformed JSON (before
`welcome` it simply gets no answer).

## Versioning

`v` = **4** in `hello` is the protocol version (4 added the paths layer — session
ids, joins, `RELIABLE`/`ACK`, `path.*` — and the direct-link messages; 3 added
`window.content`, which every VIDEO_CONFIG needs). `VIDEO_CHUNK` (0x06) is a v4
lossy type added with the 2026-11 audio fix: it stays v4 because a v4 peer that
does not advertise `videoChunks` still receives and reads whole `VIDEO_FRAME`s,
and a peer that does not know 0x06 ignores it. A phone sends chunks only to a
Mac whose hello carried `videoChunks:true`. `window.still` is an ordinary
phone→Mac JSON message under v4: it travels as a reliable, seq'd frame like every
other JSON frame, and an unknown `t` is still ignored. Both apps ship together and
there is no older-peer mode: a peer that does not serve 4 replies
`{"t":"error","code":"version","v":4}` and closes, in both directions.
`v` is the refusing side's own version, so the other side can compare it with
its own and say which app to update: the phone's `v` below the Mac's (or absent,
as from a v3 phone) means "Update Contigua on your phone."; above means
"Update Contigua on this Mac.". The Mac stops retrying. The phone's own screen
names the Mac's side the same way from the `hello`'s `v`. There is no v1
negotiation, no plaintext fallback and no reduced transport (v2 and v3 are
TLS-only). The mDNS TXT `v` is the discovery record's own generation (`1`), a
Mac ignores records with another value.
