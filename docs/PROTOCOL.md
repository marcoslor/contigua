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

- Order on open: `window.opened` (JSON), then VIDEO_CONFIG, then VIDEO_FRAMEs, the
  first a keyframe.
- One VIDEO_FRAME = exactly one access unit (one MediaCodec output buffer).
- On resize the phone sends a **new VIDEO_CONFIG** (new size) followed by a
  keyframe. The Mac must rebuild its format description on every CONFIG. Frames
  received before the new CONFIG are old-size frames and may be shown or dropped.
  `window.resume` and `window.keyframe` may also be answered with CONFIG + keyframe.
- No frames are sent while the display content is static (that's normal).
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
2. Mac → `{"t":"hello","v":2,"clientId":"<uuid>","name":"<Mac name>","id":"<the Mac's identity id>"}`.
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
   `{"t":"error","code":"pair_denied"}` and a close, so a LAN peer cannot make
   the phone prompt again in a loop. A scanned QR is still honoured: it needs
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
| `apps.icon` | `pkg` | phone replies `icon` (with `fg`/`bg`/`mono` layers when the icon is adaptive) |
| `window.open` | `stream`, `w`, `h`, `dpi`, and `pkg` (+ optional `activity`) **or** `"mode":"phone"` | create VD + encoder, launch app on it; `mode: phone` mirrors display 0 instead (`window.opened` has `displayId` 0 and the size at the phone screen's aspect inside `w`×`h`; a rotation sends a new VIDEO_CONFIG with the turned size; error `mirror_unavailable` if the phone can't) |
| `window.resize` | `stream`, `w`, `h`, `dpi` | resize VD + reconfigure encoder; phone sends new VIDEO_CONFIG |
| `window.close` | `stream` | tear down that VD/encoder |
| `window.pause` | `stream` | Mac window hidden/minimized/occluded: stop encoding (keep VD + app alive) |
| `window.resume` | `stream` | resume; phone sends CONFIG + keyframe |
| `window.keyframe` | `stream` | request IDR (decoder error recovery) |
| `window.quality` | `stream`, `bitrate` (bps, optional), `maxFps` (optional) | live encoder quality; optional, the phone may ignore it |
| `link.open` | `stream`, `w`, `h`, `dpi`, `url` | like `window.open`, but the phone starts `ACTION_VIEW` for `url` on the new display and Android picks the app; see "Links" |
| `window.launch` | `stream`, `pkg` (+`activity`) | launch an app onto an existing window's display (phone mode) |
| `task.continue` | `stream`, `w`, `h`, `dpi` | "Continue on Mac" (docs/design/handoff.md): open a virtual display for [stream] like `window.open` and move the app that is in the foreground on the phone's own screen onto it, keeping the task. On success `window.opened` (see below) with `"started":"moved"`; when the move is refused the package is relaunched on the display instead and `started` is `"fresh"`; when nothing continuable runs in the foreground the phone answers `error code nothing_to_continue` and opens nothing |
| `nav` | `stream`, `action`: `back`/`home`/`recents` | back = KEYCODE_BACK on that display; home/recents (HOME / APP_SWITCH on display 0) only in phone mode |
| `text` | `stream`, `text` | type text into the focused field of that display |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
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
| `fs.list` | `id`, `path`, `page`? | children of `path`; `page` is the phone's opaque cursor, absent = first |
| `fs.stat` | `id`, `path` | one item's metadata |
| `fs.read` | `id`, `path`, `offset`, `length`, `etag`? | stream `length` bytes from `offset` (`FS_DATA`, then `fs.read.end`); an `etag` that no longer matches answers `fs_stale` |
| `fs.cancel` | `id` | abandon a running `fs.read`; the phone stops streaming and drops what is queued |

Phone → Mac:

| t | fields |
|---|---|
| `pong` | `ts` |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
| `apps` | `apps`: `[{"pkg","label","activity"}]` — launchable activities, sorted by label |
| `icon` | `pkg`, `png` (base64, 96×96 px); for an adaptive icon also the whole 108 dp layers as base64 PNGs at 216×216 px: `fg`, `bg` and, when present (API 33+), `mono` — optional, so an old Mac ignores them. Mac ▸ docs/design/mac-redesign.md for how the Deck uses them |
| `window.opened` | `stream`, `displayId`, `w`, `h` — `started`: `"moved"` (default; the task the display shows was moved to it, state kept) or `"fresh"` (the phone couldn't move the task and relaunched the same package; the app's state may be lost) |
| `window.closed` | `stream`, `reason` (`requested`/`app_exited`/`error`) |
| `window.title` | `stream`, `label`, `pkg` — top app changed on that display (phone mode) |
| `state` | `locked`: bool, `battery`: int, `charging`: bool, `dnd`: `"off"`/`"priority"`/`"alarms"`/`"none"`, `ringer`: `"normal"`/`"vibrate"`/`"silent"` — sent on change; `dnd`/`ringer` are absent on a phone that does not support them (old builds) |
| `audio.state` | `on`: bool, `codec`: int — audio capture on/off (for the UI dot) |
| `ring.state` | `ringing`: bool — a `phone.ring` started (`true`) or ended (`false`) |
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
  (`org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`).
- Either side may turn sync off. While it is off the side neither sends nor
  applies `clip.set`.

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

`fs.watch` and `fs.changes` are designed (design §2, §5) but are not part of
the wire yet.

## Notifications + media

Phone notifications and media controls (docs/design/notify.md) travel only
while both gates are on: the Mac's per-phone opt-in and the phone's own toggle.

Mac → phone:

| t | fields | meaning |
|---|---|---|
| `notify.enable` | `on` | the Mac's per-phone opt-in; the phone answers `notify.state` |
| `notify.open` | `id`, `target` (`window`/`phone`), `stream` (window only) | a banner click: run that forwarded notification's own action |
| `notify.action` | `id`, `i`, `text`? | press that forwarded notification's advertised action; `text` only for a reply action |
| `notify.dismiss` | `id` | clear that forwarded notification on the phone |
| `media.command` | `action`: `play`/`pause`/`next`/`prev` | drive the phone's playing session |

Phone → Mac:

| t | fields |
|---|---|
| `notify.state` | `on` — forwarding is live (both gates) |
| `notify.post` | `id`, `pkg`, `app`?, `when`, `title`?, `text`?, `ongoing`?, `actions`? |
| `notify.remove` | `id` |
| `media.state` | `playing`, `pkg`?, `title`?, `artist`?, `album`?, `durationMs`?, `positionMs`, `rate` |

`actions` is an array of up to 3 `{"i": <index in the phone's Notification.actions>,
"title": "≤ 64 chars", "reply": true?}`; `reply` marks an action with a free-form RemoteInput.
A Mac that does not know the field ignores it. `notify.action` names only an id the phone
issued and an advertised index (0–2); its `text` is at most 4 KiB and is refused on a
non-reply action or over the cap. The phone answers nothing: the app's own update/removal
comes back as `notify.post`/`notify.remove`. An id or index it does not hold logs
`notify.action unknown` without the text. `notify.dismiss` cancels the phone's notification
(the listener calls `cancelNotification`), skipping ongoing and no-clear ones.

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
identity changed. Pair again."), `pair_denied`, `pair_commit` (the revealed nonce does
not match the commit), `version`, `protocol` (message not allowed in the current state;
then close), `pair_timeout` (nobody answered the pairing prompt in 120 s; then close),
`no_stream` (unknown `stream`), `launch_failed`, `bad_url` (a `link.open` URL that is
not allowed), `bad_size` (`task.continue` without w/h) — plus the device commands'
own codes: `dnd_on` (a `phone.ringer` while Do Not Disturb is on) and `unavailable`
(the phone would not write the ringer setting), `connections_off` (the phone's
"Allow connections" switch is off: the Mac shows "Connections are turned off on
<phone name>."), `pairing_off` (the phone's "Allow new pairings" switch is off and
this Mac is not paired: "<phone name> isn't accepting new pairings."),
`not_available` (the phone can't
report its foreground app, e.g. no task manager access), `nothing_to_continue` (the
foreground is our app, the launcher/home or SystemUI), `fs_not_found`,
`fs_denied` (a path outside the readable rules, or a range outside the file),
`fs_not_a_dir`, `fs_stale` (the `fs.read` etag no longer matches the file) and
`fs_busy` (more than 8 reads in flight).
Oversized frames close the session without a reply. JSON nesting is capped at
64 arrays/objects; deeper input is rejected like any malformed JSON (before
`welcome` it simply gets no answer).

## Versioning

`v` = **2** in `hello` is the protocol version. The mDNS TXT `v` is the
discovery record's own generation (`1`), a Mac ignores records with another
value. A phone that can't serve the Mac's protocol version replies
`{"t":"error","code":"version"}` and closes; there is no v1 negotiation and
no plaintext fallback (v2 is TLS-only).
