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
| `state` | `locked`: bool, `battery`: int, `charging`: bool — sent on change |
| `audio.state` | `on`: bool, `codec`: int — audio capture on/off (for the UI dot) |
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

## Notifications + media

Phone notifications and media controls (docs/design/notify.md) travel only
while both gates are on: the Mac's per-phone opt-in and the phone's own toggle.

Mac → phone:

| t | fields | meaning |
|---|---|---|
| `notify.enable` | `on` | the Mac's per-phone opt-in; the phone answers `notify.state` |
| `notify.open` | `id`, `target` (`window`/`phone`), `stream` (window only) | a banner click: run that forwarded notification's own action |
| `media.command` | `action`: `play`/`pause`/`next`/`prev` | drive the phone's playing session |

Phone → Mac:

| t | fields |
|---|---|
| `notify.state` | `on` — forwarding is live (both gates) |
| `notify.post` | `id`, `pkg`, `app`?, `when`, `title`?, `text`?, `ongoing`? |
| `notify.remove` | `id` |
| `media.state` | `playing`, `pkg`?, `title`?, `artist`?, `album`?, `durationMs`?, `positionMs`, `rate` |

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

## Error codes

`{"t":"error","code":...}` codes: `busy` (another session is active), `bad_pin` (the
peer's certificate fingerprint is not the pinned one — the Mac shows "This phone's
identity changed. Pair again."), `pair_denied`, `pair_commit` (the revealed nonce does
not match the commit), `version`, `protocol` (message not allowed in the current state;
then close), `pair_timeout` (nobody answered the pairing prompt in 120 s; then close),
`no_stream` (unknown `stream`), `launch_failed`, `bad_url` (a `link.open` URL that is
not allowed), `bad_size` (`task.continue` without w/h), `connections_off` (the phone's
"Allow connections" switch is off: the Mac shows "Connections are turned off on
<phone name>."), `pairing_off` (the phone's "Allow new pairings" switch is off and
this Mac is not paired: "<phone name> isn't accepting new pairings."),
`not_available` (the phone can't
report its foreground app, e.g. no task manager access), `nothing_to_continue` (the
foreground is our app, the launcher/home or SystemUI).
Oversized frames close the session without a reply. JSON nesting is capped at
64 arrays/objects; deeper input is rejected like any malformed JSON (before
`welcome` it simply gets no answer).

## Versioning

`v` = **2** in `hello` is the protocol version. The mDNS TXT `v` is the
discovery record's own generation (`1`), a Mac ignores records with another
value. A phone that can't serve the Mac's protocol version replies
`{"t":"error","code":"version"}` and closes; there is no v1 negotiation and
no plaintext fallback (v2 is TLS-only).
