# PocketDeck wire protocol — v1

The single source of truth for Mac ⇄ phone traffic. Both sides MUST implement
exactly this. Change it here first, then in code.

## Transport

- **LAN only.** The phone listens on TCP (ephemeral port) and advertises it
  over mDNS/DNS-SD as service type `_pocketdeck._tcp.` with TXT records:
  `v=1`, `id=<deviceId>` (stable random hex, 16 chars), `name=<device name>`,
  `model=<Build.MODEL>`.
- The Mac connects **one TCP connection per phone** (the "session"). Everything
  — control, input and every video stream — is multiplexed on it.
- Both ends set `TCP_NODELAY`. Byte order is **big-endian** everywhere.
- (v1 is plaintext + HMAC auth. TLS is a later milestone; keep framing
  transport-agnostic.)

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
| `0x10` | TOUCH | mac→phone | `u8 action` (0 down, 1 up, 2 move, 3 cancel) · `u8 pointerId` · `f32 nx` · `f32 ny` — one frame per pointer; the phone stamps each event with its arrival time, so the Mac sends them as they happen (a drag's cadence is its fling velocity) |
| `0x11` | SCROLL | mac→phone | `f32 nx` · `f32 ny` · `f32 hscroll` · `f32 vscroll` — mouse-wheel units, injected as `ACTION_SCROLL` (`SOURCE_MOUSE`) with these as `AXIS_HSCROLL` / `AXIS_VSCROLL` at (nx, ny). `vscroll > 0` = content moves down (wheel up), `hscroll > 0` = content moves left (wheel right). One unit is one wheel notch (Android's default 64 dp scroll factor); fractions are fine. The Mac sends SCROLL for mouse wheels only: a trackpad's two-finger scroll is a one-finger drag in TOUCH (DOWN, MOVEs, UP), so Android's own drag, overscroll and fling apply |
| `0x12` | KEY | mac→phone | `u8 action` (0 down, 1 up) · `u32 keycode` (Android `KEYCODE_*`) · `u32 metaState` |

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

## Session handshake

1. Mac → `{"t":"hello","v":1,"clientId":"<uuid>","name":"<Mac name>"}`
2. Phone → `{"t":"challenge","nonce":"<32 hex>","id":"<deviceId>"}` (`id` = the mDNS TXT
   `id`, so a Mac that connected by address knows which stored key to use)
3. Paired Mac → `{"t":"auth","mac":"<hex>"}` where `mac` = lowercase hex of
   HMAC-SHA256(key = the 32 raw key bytes, message = UTF-8 bytes of the nonce
   hex string as sent);
   unpaired Mac → `{"t":"pair.request"}` (see Pairing).
4. Phone → `{"t":"welcome","device":{"id":..,"name":..,"model":..,"sdk":36,
   "screen":{"w":1080,"h":2340,"dpi":450},"locked":true}}` or
   `{"t":"error","code":"auth_failed"}` and closes.

Nothing but hello/challenge/auth/pair.request is accepted before `welcome`.

## Pairing (first contact)

Numeric comparison, like Bluetooth: both screens show the same 6-digit code and the
person taps Allow on the phone. Nothing is typed, and the Mac sends nothing after
`pair.request`.

1. Mac → `{"t":"pair.request"}`.
2. Phone generates a random 6-digit code, shows it in an Android notification/dialog
   ("Pair with <Mac name>? Code 123 456" + Allow/Deny) and replies
   `{"t":"pair.code_shown","code":"123456"}`. The code is new in this message; it is
   exactly six ASCII digits (leading zeros kept). The Mac shows it grouped "123 456".
3. The person compares the two screens and taps **Allow** or **Deny** on the phone.
   - Allow: the phone generates a random 32-byte key, stores `{clientId, name, key}`
     and replies `{"t":"pair.ok","key":"<64 hex>"}` immediately followed by `welcome`.
     The Mac stores the key under the device id (a 0600 file in its profile folder).
   - Deny: `{"t":"error","code":"pair_denied"}`, then the phone closes.
   - No decision within **120 s**: `{"t":"error","code":"pair_timeout"}`, then the
     phone closes.
4. If the Mac closes the connection first (Cancel, network loss), the phone discards
   the request and dismisses its prompt.

Timing rules:

- While a pairing request is open the phone applies no read timeout to the
  connection (the 15 s handshake timeout ends at `pair.request`); the 120 s decision
  window is the only limit. A Mac must not apply a per-attempt connect timeout to a
  session that has received `pair.code_shown`; it may keep its own backstop of 125 s
  from that message.
- One pairing request per session; a second `pair.request` is ignored.
- A phone that predates `code` in `pair.code_shown` expects `pair.confirm`; the Mac
  treats a `pair.code_shown` without `code` as an incompatible version.

**The code is displayed only, never typed.** A later milestone (E2E) derives the code
from both TLS certificate fingerprints, so that comparing the screens authenticates
the channel against a man in the middle. For that to hold the code must never become
an input path (no field, no `pair.confirm`): the phone's Allow is the confirmation.

## JSON messages

Mac → phone (after `welcome`):

| t | fields | meaning |
|---|---|---|
| `ping` | `ts` | phone replies `pong` with same `ts` |
| `apps.list` | — | phone replies `apps` |
| `apps.icon` | `pkg` | phone replies `icon` |
| `window.open` | `stream`, `w`, `h`, `dpi`, and `pkg` (+ optional `activity`) **or** `"mode":"phone"` | create VD + encoder, launch app (or the PocketDeck launcher for phone mode) on it |
| `window.resize` | `stream`, `w`, `h`, `dpi` | resize VD + reconfigure encoder; phone sends new VIDEO_CONFIG |
| `window.close` | `stream` | tear down that VD/encoder |
| `window.pause` | `stream` | Mac window hidden/minimized/occluded: stop encoding (keep VD + app alive) |
| `window.resume` | `stream` | resume; phone sends CONFIG + keyframe |
| `window.keyframe` | `stream` | request IDR (decoder error recovery) |
| `window.quality` | `stream`, `bitrate` (bps, optional), `maxFps` (optional) | live encoder quality; optional, the phone may ignore it |
| `link.open` | `stream`, `w`, `h`, `dpi`, `url` | like `window.open`, but the phone starts `ACTION_VIEW` for `url` on the new display and Android picks the app; see "Links" |
| `window.launch` | `stream`, `pkg` (+`activity`) | launch an app onto an existing window's display (phone mode) |
| `nav` | `stream`, `action`: `back`/`home`/`recents` | back = KEYCODE_BACK on that display; home/recents meaningful in phone mode |
| `text` | `stream`, `text` | type text into the focused field of that display |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |

Phone → Mac:

| t | fields |
|---|---|
| `pong` | `ts` |
| `clip.set` | `text` | plain-text clipboard, either direction; see "Clipboard sync" |
| `apps` | `apps`: `[{"pkg","label","activity"}]` — launchable activities, sorted by label |
| `icon` | `pkg`, `png` (base64, 96×96 px) |
| `window.opened` | `stream`, `displayId`, `w`, `h` |
| `window.closed` | `stream`, `reason` (`requested`/`app_exited`/`error`) |
| `window.title` | `stream`, `label`, `pkg` — top app changed on that display (phone mode) |
| `state` | `locked`: bool, `battery`: int, `charging`: bool — sent on change |
| `error` | `code`, `message`, optional `stream` |

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

## Error codes

`{"t":"error","code":...}` codes: `busy` (another session is active; sent instead of
`challenge`, then close), `auth_failed`, `pair_denied`, `version`, `protocol` (message not
allowed in the current state; then close), `pair_timeout` (nobody answered the pairing prompt in 120 s; then close), `no_stream` (unknown `stream`), `launch_failed`, `bad_url` (a `link.open` URL that is not allowed).
Oversized frames close the session without a reply.

## Versioning

`v` in hello + mDNS TXT. A phone that can't serve the Mac's `v` replies
`{"t":"error","code":"version"}` and closes.
