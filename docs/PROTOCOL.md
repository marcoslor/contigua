# PocketDeck wire protocol — v2

The single source of truth for Mac ⇄ phone traffic. Both sides MUST implement
exactly this. Change it here first, then in code.

## Transport

- **LAN only.** The phone listens on TCP (ephemeral port) and advertises it
  over mDNS/DNS-SD as service type `_pocketdeck._tcp.` with TXT records:
  `v=1` (the discovery record's generation), `id=<deviceId>` (stable random
  hex, 16 chars), `name=<device name>`, `model=<Build.MODEL>`. No fingerprint
  or other tracking identifier rides in the TXT. While the phone's "Allow
  connections" switch is off it stops advertising and keeps the listener up:
  a Mac that already has the address is refused (see "Error codes"), and
  turning the switch back on advertises the same port again.
- **TLS 1.3, mutual, pinned — no plaintext, no v1.** The phone wraps every
  accepted connection in a platform `SSLSocket` (Conscrypt) and the Mac dials
  with NIOSSL/BoringSSL (docs/design/e2ee.md §1/§2). Both ends: TLS 1.3 only,
  client auth required, session resumption and 0-RTT disabled, and the peer
  certificate pinned (the phone pins the Mac's certificate fingerprint, the
  Mac pins the phone's). There is no plaintext phase and no v1 fallback: a
  client that does not complete the handshake is closed without a byte.
- The Mac connects **one TCP connection per phone** (the "session"). Everything
  — control, input and every video stream — is multiplexed on it.
- Both ends set `TCP_NODELAY`. Byte order is **big-endian** everywhere.

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
| `0x02` | VIDEO_CONFIG | phone→mac | `u8 codec` (1 = H.264) · `u16 width` · `u16 height` · Annex-B SPS+PPS bytes |
| `0x03` | VIDEO_FRAME | phone→mac | `u64 ptsUs` · `u8 flags` (bit0 = keyframe) · Annex-B access unit |
| `0x04` | AUDIO_CONFIG | phone→mac | `u8 codec` (2 = Opus, 3 = AAC-LC) · `u32 sampleRate` · `u8 channels` · `u16 frameMs` · codec setup bytes (Opus: empty; AAC: ASC) |
| `0x05` | AUDIO_FRAME | phone→mac | `u64 ptsUs` · one encoder packet (one Opus frame or one AAC access unit) |
| `0x10` | TOUCH | mac→phone | `u8 action` (0 down, 1 up, 2 move, 3 cancel) · `u8 pointerId` · `f32 nx` · `f32 ny` — one frame per pointer; the phone stamps each event with its arrival time, so the Mac sends them as they happen (a drag's cadence is its fling velocity) |
| `0x11` | SCROLL | mac→phone | `f32 nx` · `f32 ny` · `f32 hscroll` · `f32 vscroll` — mouse-wheel units, injected as `ACTION_SCROLL` (`SOURCE_MOUSE`) with these as `AXIS_HSCROLL` / `AXIS_VSCROLL` at (nx, ny). `vscroll > 0` = content moves down (wheel up), `hscroll > 0` = content moves left (wheel right). One unit is one wheel notch (Android's default 64 dp scroll factor); fractions are fine. The Mac sends SCROLL for mouse wheels only: a trackpad's two-finger scroll is a one-finger drag in TOUCH (DOWN, MOVEs, UP), so Android's own drag, overscroll and fling apply |
| `0x12` | KEY | mac→phone | `u8 action` (0 down, 1 up) · `u32 keycode` (Android `KEYCODE_*`) · `u32 metaState` |
| `0x13` | HOVER | mac→phone | `u8 action` (0 enter, 1 move, 2 exit) · `f32 nx` · `f32 ny` — the Mac pointer over the video with no button down, injected as `ACTION_HOVER_ENTER`/`MOVE`/`EXIT` (`SOURCE_MOUSE`, tool type mouse) at (nx, ny) on the stream's display. Moves are coalesced on both sides (at most one per 16 ms; the phone keeps only the newest when it is still injecting). No hover while a button is down: the Mac sends EXIT, then the TOUCH DOWN. A phone that does not know this type ignores it |
| `0x20` | APK_DATA | mac→phone | the next bytes (≤ 1 MiB) of an APK install; `stream` = the install `id`; see "APK install" |
| `0x21` | SHARE_DATA | phone→mac | the next bytes (≤ 1 MiB) of a shared file; `stream` = the share `id`; see "Share phone → Mac" |
| `0x22` | DROP_DATA | mac→phone | the next bytes (≤ 1 MiB) of a file dropped on a window; `stream` = the drop `id`; see "Drop Mac → phone" |
| `0x23` | CLIP_DATA | both | the next bytes (≤ 1 MiB) of a clipboard image; `stream` = the image `id`; see "Clipboard images" |
| `0x24` | FS_DATA | both | the next bytes (≤ 256 KiB) of an `fs.read` or `fs.write`; `stream` = the request `id`; see "Phone files" |

`nx`,`ny` are normalized `[0,1]` in the stream's video coordinates (top-left
origin). The phone maps them to the stream's current virtual display size.
Input frames carry the window's `stream` id; the phone stamps the matching
display id on every injected event.

`f32` = IEEE-754 single, big-endian.

### Video rules

- Order on open: `window.opened` (JSON), then `window.content` and VIDEO_CONFIG, then
  VIDEO_FRAMEs, the first a keyframe.
- **`window.content`** (JSON, phone→mac, sent on the same lane just before every
  VIDEO_CONFIG): `{"t":"window.content","stream":N,"x":X,"y":Y,"w":W,"h":H}` is where the
  picture sits in the config's frame, in frame pixels with a top-left origin. It is
  required: a VIDEO_CONFIG without one is dropped by the Mac. An app window's picture is the
  whole frame. A phone mirror's frame may carry black outside its picture (the encoder's
  size and the screen's aspect differ; the picture is centred); the Mac shows only the
  picture, scaled to fill its window, and its aspect lock follows the picture's, not the
  frame's. Input maps over the picture, which is the screen.
- One VIDEO_FRAME = exactly one access unit (one MediaCodec output buffer).
- On resize the phone sends a **new VIDEO_CONFIG** (new size) followed by a
  keyframe, then `window.resize.ack`. The Mac must rebuild its format description on
  every CONFIG. Frames received before the new CONFIG are old-size frames and may be
  shown or dropped. `window.resume` and `window.keyframe` may also be answered with
  CONFIG + keyframe. A resize that changes only the dpi keeps the frame size, so it
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
- The display content being static is not silence: the encoder repeats its
  last frame at least every 500 ms (`KEY_REPEAT_PREVIOUS_FRAME_AFTER`) while a
  stream is open, so a live stream is never quiet for long. That heartbeat is
  what lets the Mac tell a static picture from a stalled encoder (it says "Not
  responding" after 1.5 s without frames).
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

## Session handshake

1. The TLS 1.3 handshake completes with both certificates exchanged and
   verified against the pinned peer (an unpaired phone accepts the Mac's
   certificate and pins it only on a successful pairing; a paired phone
   refuses a Mac whose certificate fingerprint is not the pinned one with
   `{"t":"error","code":"bad_pin"}` and closes — "This phone's identity
   changed" on the Mac side is the same rule in the other direction).
2. Mac → `{"t":"hello","v":3,"clientId":"<uuid>","name":"<Mac name>","id":"<the Mac's identity id>"}`.
   A `v` other than 2 gets `{"t":"error","code":"version"}` and a close.
3. The phone knows the Mac by `clientId` and applies its two connection
   switches before anything else. "Allow connections" off refuses every Mac,
   paired or not, with `{"t":"error","code":"connections_off"}` and a close —
   but only a Mac whose certificate matches a stored pin ever hears that
   message; any other peer is closed without a reply once TLS completes. The
   TLS handshake runs under a 10 s read timeout on a small worker pool, so one
   silent TCP peer never blocks the next connection.
   "Allow new pairings" off refuses an unpaired Mac the same way with
   `{"t":"error","code":"pairing_off"}` before any code exists; paired Macs
   continue. If the phone cannot read the switches it refuses like
   `connections_off` (fail closed). Otherwise:
   - **Paired**: its pinned fingerprint must equal the TLS peer's fingerprint;
     then the phone sends `welcome` and the session is ready.
   - **Unpaired**: the phone waits in the pairing phase (next section). The
     Mac asks for the code flow with `{"t":"pair.request"}`; a scanned QR is
     answered by the phone itself with `pair.qr` (see Pairing).
4. Phone → `{"t":"welcome","device":{"id":..,"name":..,"model":..,"sdk":36,
   "screen":{"w":1080,"h":2340,"dpi":450},"locked":true}}`. The phone allows
   exactly one session at a time: a second connection gets
   `{"t":"error","code":"busy","message":"one session at a time"}` and a close.

Nothing but `hello`, `pair.request`, `pair.nonce` and `pair.ok` is accepted
before `welcome`; anything else is `{"t":"error","code":"protocol"}` and a
close.

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
exporter = TLS-Exporter("EXPORTER-pocketdeck-pair", empty context, 32 bytes)
code     = uint64_be(SHA-256("pd-code-v2" || exporter || macFP || phoneFP
                             || Nm || Np)[0..8]) mod 1_000_000   // "123 456"
```

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

The Mac shows `pocketdeck://pair?c=<clientId>&n=<name>&f=<macFP hex 64>&s=<S hex 32>`,
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
| `ping` | `ts` | phone replies `pong` with same `ts` |
| `apps.list` | — | phone replies `apps` |
| `apps.icon` | `pkg`, optional `px` | phone replies `icon` (with `fg`/`bg`/`mono` layers when the icon is adaptive); `px` is the pixel side of the 108 dp layer it should render (default 216, clamped to 216…1296), an older phone ignores it |
| `window.open` | `stream`, `w`, `h`, `dpi`, and `pkg` (+ optional `activity`) **or** `"mode":"phone"`, and `newInstance` (optional bool, planned, epic multiwin) | create VD + encoder, launch app on it; `mode: phone` mirrors display 0 instead (`window.opened` has `displayId` 0 and the frame's size, the codec's nearest size to the screen's aspect inside `w`×`h`, with the screen's picture in it as `window.content` says; a rotation sends a new VIDEO_CONFIG with the turned size; error `mirror_unavailable` if the phone can't). `newInstance: true` (planned) asks for another task of the app on this display: the phone adds `FLAG_ACTIVITY_NEW_DOCUMENT \| FLAG_ACTIVITY_MULTIPLE_TASK` to the launch Intent, so the activity's own `launchMode`/`documentLaunchMode` still decides whether a second task appears; past the phone's cap it answers error `too_many_windows` |
| `window.resize` | `stream`, `w`, `h`, `dpi` | resize VD + reconfigure encoder; phone sends new VIDEO_CONFIG, then `window.resize.ack`. A request equal to what the display already shows is a no-op; the same size at a new dpi changes the display's density and rebuilds no encoder (so no new VIDEO_CONFIG); one the phone cannot apply answers `refused` |
| `window.close` | `stream` | tear down that VD/encoder |
| `window.pause` | `stream` | Mac window hidden/minimized/occluded: stop encoding (keep VD + app alive) |
| `window.resume` | `stream` | resume; phone sends CONFIG + keyframe |
| `window.keyframe` | `stream` | request IDR (decoder error recovery) |
| `window.quality` | `stream`, `bitrate` (bps, optional), `maxFps` (optional) | live encoder quality; optional, the phone may ignore it |
| `link.open` | `stream`, `w`, `h`, `dpi`, `url` | like `window.open`, but the phone starts `ACTION_VIEW` for `url` on the new display and Android picks the app; see "Links" |
| `window.launch` | `stream`, `pkg` (+`activity`) | launch an app onto an existing window's display (phone mode) |
| `task.continue` | `stream`, `w`, `h`, `dpi` | "Move Phone App to Mac" (docs/design/handoff.md): open a virtual display for [stream] like `window.open` and move the app that is in the foreground on the phone's own screen onto it, keeping the task. On success `window.opened` (see below) with `"started":"moved"`; when the move is refused the package is relaunched on the display instead and `started` is `"fresh"`; when nothing continuable runs in the foreground the phone answers `error code nothing_to_continue` and opens nothing |
| `nav` | `stream`, `action`: `back`/`home`/`recents` | back = KEYCODE_BACK on that display; home/recents (HOME / APP_SWITCH on display 0) only in phone mode |
| `text` | `stream`, `text` | type text into the focused field of that display |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
| `clip.enable` | `on` | the Mac's clipboard switch: the phone sends and applies no `clip.set` or `clip.image.*` while it is off; see "Clipboard sync" |
| `apk.install` | `id`, `files`: `[{"name","size","sha256"}]` | start an APK install; `APK_DATA` frames follow; see "APK install" |
| `apk.cancel` | `id` | abandon that install |
| `drop.start` | `id`, `name`, `mime`, `size`, `sha256`, optional `resume` | start a file drop (a Finder drag onto a phone window); `DROP_DATA` frames follow; see "Drop Mac → phone" |
| `drop.cancel` | `id` | abandon that drop |
| `clip.image.start` | `id`, `mime`, `size` | a clipboard image follows in `CLIP_DATA` frames; see "Clipboard images" |
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
| `fs.read` | `id`, `path`, `offset`, `length`, `etag`? | stream `length` bytes from `offset` (`FS_DATA`, then `fs.read.end`); an `etag` that no longer matches answers `fs_stale` |
| `fs.cancel` | `id` | abandon a running `fs.read`; the phone stops streaming and drops what is queued |

Phone → Mac:

| t | fields |
|---|---|
| `pong` | `ts` |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
| `apps` | `apps`: `[{"pkg","label","activity"}]` — launchable activities, sorted by label; `multi` (planned, epic multiwin) says whether a second instance can run: false only when the launcher activity's `launchMode` is `singleTask`/`singleInstance` or its `documentLaunchMode` is `never` |
| `icon` | `pkg`, `png` (base64, 96×96 px, or 2/3 of `px` when the request had one); for an adaptive icon also the whole 108 dp layers as base64 PNGs at the requested `px` (216×216 px by default): `fg`, `bg` and, when present (API 33+), `mono` — optional, so an old Mac ignores them. Mac ▸ docs/design/dock.md §Icons for how the icons are drawn |
| `window.opened` | `stream`, `displayId`, `w`, `h`, `taskId` (planned: the task the display shows) — `started`: `"moved"` (default; the task the display shows was moved to it, state kept) or `"fresh"` (the phone couldn't move the task and relaunched the same package; the app's state may be lost) |
| `window.closed` | `stream`, `reason` (`requested`/`app_exited`/`error`) |
| `window.resize.ack` | `stream`, `w`, `h`, `dpi` (the request echoed), `outcome`: `"resized"` (new size, new encoder), `"density"` (same size, new dpi, no encoder rebuild), `"same"` (the display already showed it) or `"kept"` (the encoder refused; the stream keeps its old size) or `"refused"` (the phone cannot apply it: no such stream, or a size of zero). Every `window.resize` is answered with one, the early returns included; the Mac keeps one resize in flight and sends the newest waiting value when this arrives, or when the stall limit passes without one |
| `window.title` | `stream`, `label`, `pkg` — the top app changed on that display (phone mode); on an app stream (planned) the task's own description (`RecentTaskInfo.taskDescription`), sent when it changes; the Mac titles the window with it while the app has several windows |
| `state` | `locked`: bool, `battery`: int, `charging`: bool, `dnd`: `"off"`/`"priority"`/`"alarms"`/`"none"`, `ringer`: `"normal"`/`"vibrate"`/`"silent"`, `volume`: int, `volumeMax`: int, `screen`: `"on"`/`"off"`, `secure`: bool, `panel`: `"on"`/`"off"`, `maxWindows` (planned: the most app windows this phone allows at once) — sent on change; `dnd`/`ringer` are absent on a phone that does not support them (old builds), `volume`/`volumeMax` are both absent on one that cannot read its music stream, `secure` while no phone window is open; see "Phone screen", "Volume" and "Secure screens" |
| `audio.state` | `on`: bool, `codec`: int — audio capture on/off (for the UI dot) |
| `ring.state` | `ringing`: bool — a `phone.ring` started (`true`) or ended (`false`) |
| `power.locked` | — the person's power press with app streams up: the phone took its panel over and is re-lighting the streaming group. The Mac holds each app window's last frame for a short grace instead of calling the picture stalled; see "Phone screen" |
| `error` | `code`, `message`, optional `stream` |
| `apk.progress` | `id`, `bytes` — bytes written into the install so far |
| `apk.result` | `id`, `ok`; success: `pkg`, `label`, `version`; failure: `code`, `message` |
| `share.text` | `text` — shared from an Android app; see "Share phone → Mac" |
| `share.file` | `id`, `name`, `mime` — a shared file follows in `SHARE_DATA` frames |
| `share.end` | `id`, `size`, `sha256` — the file is complete |
| `share.abort` | `id` — the phone gave up on that file; the Mac discards it |
| `drop.progress` | `id`, `bytes` — bytes written of a file drop |
| `drop.result` | `id`, `ok`; success: `path`; failure: `code`, `message` |
| `clip.image.start` | `id`, `mime`, `size` — sent by either side |
| `fs.items` | `id`, `page` (null = last), `items`: `[{"name","dir","size","mtime","ino","etag"}]` — no path per item; the parent is implicit |
| `fs.item` | `id`, `item` (same shape) |
| `fs.read.end` | `id`, `size`, `sha256` — the requested range is complete and correct |

Unknown `t` values and unknown binary frame types are ignored (log once). Unknown
fields are ignored. `activity` is a component string `pkg/fully.qualified.Class`.
The phone sends one `state` right after `welcome`, then on change.

### Several windows of one app (planned, epic multiwin)

`newInstance`, `taskId`, `multi`, `maxWindows` and the app-stream `window.title`
above are planned: written here so the phone and the Mac can be built against one
contract, landed together in phase 2 (`.agent/multiwin/phase2.md`). They are
additive — every one has a default a phone or Mac without it still answers — so
the protocol version stays 3. The evidence for what the platform allows and what
a window costs is `.agent/multiwin/spike.md`.

- One stream is one virtual display and one task. `newInstance` never reuses an
  existing task; without it the phone launches with `FLAG_ACTIVITY_NEW_TASK` as
  today and the platform may move the app's one task to the new display.
- `taskId` is the phone's own task id for the display; it is not stable across a
  reconnect, and the Mac keeps it only to name and close the right window.
- `window.title` on an app stream carries the task's label, not the app's; the
  phone sends it when the label changes, at most once a second.
- `maxWindows` is per phone and counts app streams only; the Phone Mirror is a
  separate encoder and is not counted. Past it, `window.open` (with or without
  `newInstance`) answers `too_many_windows`.

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
  side neither sends nor applies `clip.set` or a clipboard image — the bytes
  stay on the phone, and the Mac's own side reads the setting for its sends
  and its applies.

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

1. Mac → `{"t":"drop.start","id":N,"name":"report.pdf","mime":"application/pdf","size":S,"sha256":"<64 hex>"}`,
   `id` a u32 ≠ 0 chosen by the Mac, optional `"resume":bytes` (see 3). One drop per phone:
   while one is running a new `drop.start` answers `{"t":"drop.result","ok":false,"code":"busy"}`.
   The phone validates (`name` `[A-Za-z0-9 ._-]{1,100}`, `size` > 0 and ≤ 200 MiB
   (209 715 200 bytes), `mime` non-empty UTF-8, `sha256` 64 lowercase hex) and answers
   `{"t":"drop.result","id":N,"ok":false,"code":"bad_request","message":...}` anything else.
2. Mac → `DROP_DATA` frames with `stream` = `id` (each ≤ 1 MiB). The phone counts bytes against
   the announced `size`; more, or a stalled sender, fails the drop.
3. **Resume**: with `"resume":bytes` and a partial temp file from a same-`(name,size,sha256)`
   drop, the phone replies `{"t":"drop.progress","id":N,"bytes":verified}` (the offset) and
   appends from there; anything else answers `bytes:0` and restarts.
4. Phone → `drop.progress {id, bytes}` at most 4 per second (plus once with the last byte),
   then exactly one `drop.result`: success `{"ok":true,"path":"/sdcard/Download/PocketDeck/<name>"}`
   (the sanitised name, " 2", " 3"… on collision), failure `code`/`message` from `bad_request`,
   `too_large`, `busy`, `checksum` (the finished bytes' SHA-256 differs; the file is removed),
   `cancelled`, `failed`.
5. Mac → `drop.cancel {id}` any time; the phone abandons, removes partial data and replies
   `drop.result` `cancelled`. A session that ends abandons its drop.

The phone writes every byte to a hidden temp file in `/sdcard/Download/PocketDeck/`, renames
only after the SHA-256 matches, media-scans the file and — where sensible — offers a SEND
activity with the app's FileProvider content URI (docs/design/dragdrop.md).

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
  unknown starts at the first item. `fs.items.page` is `null` on the last page.
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
- **`fs.cancel`** stops that read: the phone sends no further `FS_DATA` for the
  id (queued chunks are dropped), and the Mac discards what it already has.
  Frames for a cancelled or unknown `id` are dropped. A session that ends
  abandons every running read.
- **Ids and caps**: `id` is a u32 ≠ 0 chosen by the Mac, one request in flight
  per id; the phone runs at most 8 reads at once and answers `fs_busy` past
  that. Every reply carries its `id`; fs failures are the ordinary `error`
  message with an `id` field.
- **Logs carry no names**: counts, lengths, depths and codes only, both sides.

### Writing

`FS_DATA` also travels Mac → phone: `stream` = the request `id`, each frame
≤ 256 KiB, paced like a drop (at most 1 MiB queued, so at most four frames in
flight). The phone writes into a hidden temp in the target folder
(`.pocketdeck-<random>.part`, never listed), verifies size and SHA-256, then
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
  for a child folder itself. Our own staging writes (`.pocketdeck-*.part`) never
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
| `notify.enable` | `on` | the Mac's per-phone opt-in (the only notification switch); the phone answers `notify.state` |
| `notify.open` | `id`, `target` (`window`/`phone`), `stream` (window only) | a banner click: run that forwarded notification's own action |
| `notify.action` | `id`, `i`, `text`? | press that forwarded notification's advertised action; `text` only for a reply action |
| `notify.dismiss` | `id` | clear that forwarded notification on the phone |
| `media.command` | `action`: `play`/`pause`/`next`/`prev`/`seek`/`volume`, `key`?, `positionMs`?, `level`? | drive the phone's chosen media session |
| `media.choose` | `key` | pick which phone session Now Playing follows |

Phone → Mac:

| t | fields |
|---|---|
| `notify.state` | `on` — forwarding is live; `reason` — `no_access` when the Mac asked but the phone's listener grant is missing |
| `notify.post` | `id`, `pkg`, `app`?, `when`, `title`?, `text`?, `ongoing`?, `actions`?, `live`? |
| `notify.image` | `id`, `mime`, `w`, `h`, `data` (base64) |
| `notify.remove` | `id` |
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

`actions` is an array of up to 3 `{"i": <index in the phone's Notification.actions>,
"title": "≤ 64 chars", "reply": true?}`; `reply` marks an action with a free-form RemoteInput.
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
  Ids are per direction, from 1.
- At most 8 MiB (8 388 608 bytes) per image. Larger: the sender stays silent, a receiver that
  sees `size` over the cap ignores the image — the `clip.set` rule for bytes.
- One image in flight per direction: a new `clip.image.start` replaces the unfinished one, and
  session end discards it.
- The Mac sends an image when the general pasteboard changes to an item with image data and no
  text (PNG verbatim, TIFF converted to PNG) and it is not marked concealed by a password
  manager. From the phone the image is read out of the clipboard's first item when its bytes
  are readable. The receiver keeps the SHA-256 of the bytes it last sent or received, so images
  are never echoed back, like `clip.set`.

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
   Android 16 a ringer change can end an "alarms" DND, and PocketDeck does not turn off a
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
6. A power press with app windows open (no phone window) may sleep the panel's whole display
   group: on a build that ignores `OWN_DISPLAY_GROUP` the streaming virtual displays share
   display 0's group (docs/ARCHITECTURE.md). The phone then wakes the streaming group at once
   and powers the panel off under it — the same take-over an episode start uses — so the
   windows keep rendering. The press still locks the phone: nothing dismisses or unlocks the
   keyguard. The phone sends one `{"t":"power.locked"}` on that edge, and the Mac holds each
   app window's last frame for a grace shorter than `stale_picture_ms` before it says "Not
   responding", so the press does not read as a dead stream. It sends nothing for a press
   while the panel is already held (point 4): that one hands the phone back instead.

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
3. The phone remembers whether PocketDeck turned DND on. `phone.dnd off` turns it off only
   when that is still the mode PocketDeck set; a mode the person chose is never turned off.
   The memory lives in the shell service, survives a disconnect and is cleared on reboot.
4. Every `state` carries `dnd` while the phone supports it; a person's change on the phone
   arrives as the next `state`. A phone that predates this field omits it, and the Mac reads
   that as "not supported".

## Error codes

`{"t":"error","code":...}` codes: `busy` (another session is active), `bad_pin` (the
peer's certificate fingerprint is not the pinned one — the Mac shows "This phone's
identity changed. Pair again."), `pair_denied`, `pair_cooldown`, `pair_commit` (the revealed nonce does
not match the commit), `version`, `protocol` (message not allowed in the current state;
then close), `pair_timeout` (nobody answered the pairing prompt in 120 s; then close),
`no_stream` (unknown `stream`), `launch_failed`, `bad_url` (a `link.open` URL that is
not allowed), `bad_size` (`task.continue` without w/h) — plus the device commands'
own codes: `dnd_on` (a `phone.ringer` while Do Not Disturb is on) and `unavailable`
(the phone would not write the ringer setting or the music volume), `connections_off` (the phone's
"Allow connections" switch is off: the Mac shows "Connections are turned off on
<phone name>."), `pairing_off` (the phone's "Allow new pairings" switch is off and
this Mac is not paired: "<phone name> isn't accepting new pairings."),
`not_available` (the phone can't
report its foreground app, e.g. no task manager access), `nothing_to_continue` (the
foreground is our app, the launcher/home or SystemUI), `fs_not_found`,
`fs_denied` (a path outside the readable rules, or a range outside the file),
`fs_not_a_dir`, `fs_stale` (the `fs.read` etag no longer matches the file) and
`fs_busy` (more than 8 reads in flight), `too_many_windows` (planned: a
`window.open` past the phone's `maxWindows`).
Oversized frames close the session without a reply. JSON nesting is capped at
64 arrays/objects; deeper input is rejected like any malformed JSON (before
`welcome` it simply gets no answer).

## Versioning

`v` = **3** in `hello` is the protocol version (3 added `window.content`, which every
VIDEO_CONFIG now needs). The mDNS TXT `v` is the
discovery record's own generation (`1`), a Mac ignores records with another
value. A phone that can't serve the Mac's protocol version replies
`{"t":"error","code":"version"}` and closes; there is no v1 negotiation and
no plaintext fallback (v2 is TLS-only).
